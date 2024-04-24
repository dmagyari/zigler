defmodule Zig.Nif.Basic do
  @moduledoc """
  Architecture:

  Synchronous has two different cases.  The first case is that the nif can be called
  directly.  In this case, the function is mapped directly to function name.  In the
  case that the nif needs marshalling, the function is mapped to `marshalled-<nifname>`.
  and the called function contains wrapping logic.

  To understand wrapping logic, see `Zig.Nif.Marshaller`
  """

  alias Zig.ErrorProng
  alias Zig.Nif
  alias Zig.Nif.DirtyCpu
  alias Zig.Nif.DirtyIo
  alias Zig.Nif.Synchronous
  alias Zig.Type

  import Zig.QuoteErl

  # marshalling setup

  defp needs_marshal?(nif) do
    Enum.any?(nif.signature.params, &Type.marshals_param?/1) or
      Type.marshals_return?(nif.signature.return)
  end

  defp marshal_name(nif), do: :"marshalled-#{nif.name}"

  def entrypoint(nif) do
    if needs_marshal?(nif), do: marshal_name(nif), else: nif.name
  end

  def render_elixir(%{signature: signature} = nif) do
    {empty_params, used_params} =
      case signature.arity do
        0 ->
          {[], []}

        n ->
          1..n
          |> Enum.map(&{{:"_arg#{&1}", [], Elixir}, {:"arg#{&1}", [], Elixir}})
          |> Enum.unzip()
      end

    error_text = "nif for function #{signature.name}/#{signature.arity} not bound"

    def_or_defp = if nif.export, do: :def, else: :defp

    if needs_marshal?(nif) do
      render_elixir_marshalled(nif, def_or_defp, empty_params, used_params, error_text)
    else
      quote context: Elixir do
        unquote(def_or_defp)(unquote(signature.name)(unquote_splicing(empty_params))) do
          :erlang.nif_error(unquote(error_text))
        end
      end
    end
  end

  defp render_elixir_marshalled(
         %{signature: signature} = nif,
         def_or_defp,
         empty_params,
         used_params,
         error_text
       ) do
    marshal_name = marshal_name(nif)

    marshal_params =
      signature.params
      |> Enum.zip(used_params)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{param_type, param}, index} ->
        List.wrap(
          if Type.marshals_param?(param_type) do
            Type.marshal_param(param_type, param, index, :elixir)
          end
        )
      end)

    return =
      quote do
        return
      end

    marshal_return =
      if Type.marshals_return?(signature.return) do
        Type.marshal_return(signature.return, return, :elixir)
      else
        return
      end

    quote do
      unquote(def_or_defp)(unquote(nif.name)(unquote_splicing(used_params))) do
        unquote_splicing(marshal_params)
        return = unquote(marshal_name)(unquote_splicing(used_params))
        unquote(marshal_return)
      end

      defp unquote(marshal_name)(unquote_splicing(empty_params)) do
        :erlang.nif_error(unquote(error_text))
      end
    end
  end

  def render_erlang(%{type: type} = nif) do
    {unused_vars, used_vars} =
      case type.arity do
        0 ->
          {[], []}

        n ->
          1..n
          |> Enum.map(&{{:var, :"_X#{&1}"}, {:var, :"X#{&1}"}})
          |> Enum.unzip()
      end

    error_text = ~c'nif for function #{type.name}/#{type.arity} not bound'

    if needs_marshal?(nif) do
      {marshalled_vars, marshal_code} =
        type.params
        |> Enum.zip(used_vars)
        |> Enum.map_reduce([], fn {param_type, {:var, var}}, so_far ->
          if Type.marshals_param?(param_type) do
            {{:var, :"#{var}_m"}, [so_far, Type.marshal_param(param_type, var, nil, :erlang)]}
          else
            {{:var, var}, so_far}
          end
        end)

      result_code =
        if Type.marshals_param?(type.return) do
          Type.marshal_return(type.return, :Result, :erlang)
        else
          "Result"
        end

      quote_erl(
        """
        unquote(function_name)(unquote(...used_vars)) ->

          #{marshal_code}

          try unquote(marshal_name)(unquote(...marshalled_vars)) of
            Result ->
              #{result_code}
          catch
            splice_prongs(error_prongs)
          end.

        unquote(marshal_name)(unquote(...unused_vars)) ->
          erlang:nif_error(unquote(error_text)).
        """,
        function_name: type.name,
        used_vars: used_vars,
        unused_vars: unused_vars,
        marshalled_vars: marshalled_vars,
        marshal_name: marshal_name(nif),
        error_text: error_text
      )
    else
      quote_erl(
        """
        unquote(function_name)(unquote(...vars)) ->
          erlang:nif_error(unquote(error_text)).
        """,
        function_name: type.name,
        vars: unused_vars,
        error_text: error_text
      )
    end
  end

  require EEx

  basic = Path.join(__DIR__, "../templates/basic.zig.eex")
  EEx.function_from_file(:defp, :basic, basic, [:assigns])

  raw_beam = Path.join(__DIR__, "../templates/raw_beam.zig.eex")
  EEx.function_from_file(:defp, :raw_beam, raw_beam, [:assigns])

  raw_erl_nif = Path.join(__DIR__, "../templates/raw_erl_nif.zig.eex")
  EEx.function_from_file(:defp, :raw_erl_nif, raw_erl_nif, [:assigns])

  def render_zig(nif), do: basic(nif)

  def context(DirtyCpu), do: :dirty
  def context(DirtyIo), do: :dirty
  def context(Synchronous), do: :synchronous

  def resources(_), do: []

  # TODO: move this to "nif"
  def cleanup_for(nil, param_type, index) do
    type_cleanup(param_type, index)
  end

  def cleanup_for(arg_opts, param_type, index) do
    arg_opts
    |> Enum.at(index)
    |> Keyword.get(:cleanup, true)
    |> if do
      type_cleanup(param_type, index)
    else
      "null,"
    end
  end

  def type_cleanup(param_type, index) do
    if Type.missing_size?(param_type) do
      ".{.size = size#{index}},"
    else
      ".{},"
    end
  end
end
