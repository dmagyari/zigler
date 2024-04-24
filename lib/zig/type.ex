use Protoss

defprotocol Zig.Type do
  alias Zig.Type.Array
  alias Zig.Type.Bool
  alias Zig.Type.Cpointer
  alias Zig.Type.Error
  alias Zig.Type.Float
  alias Zig.Type.Integer
  alias Zig.Type.Manypointer
  alias Zig.Type.Optional
  alias Zig.Type.Slice
  alias Zig.Type.Struct
  alias Zig.Type.Resource

  @type t ::
          Bool.t() | Enum.t() | Float.t() | Integer.t() | Struct.t() | :env | :pid | :port | :term

  @spec marshals_param?(t) :: boolean
  @doc "beam-side type conversions that might be necessary to get an elixir parameter into a zig parameter"
  def marshals_param?(type)

  @spec marshal_param(t, Macro.t(), non_neg_integer, :elixir | :erlang) :: Macro.t()
  def marshal_param(type, variable, index, platform)

  @spec marshals_return?(t) :: boolean
  @doc "beam-side type conversions that might be necessary to get a zig return into an elixir return"
  def marshals_return?(type)

  @spec marshal_return(t, Macro.t(), Elixir | :erlang) :: Macro.t()
  def marshal_return(type, variable, platform)

  # validations:

  @spec return_allowed?(t) :: boolean
  def return_allowed?(type)

  # rendered zig code:
  @spec render_payload_entry(t, non_neg_integer, boolean) :: iodata
  def render_payload_entry(type, index, error_info?)

  @spec render_return(t) :: iodata
  def render_return(type)

  @typep spec_context :: :param | :return
  @spec spec(t, spec_context, keyword) :: Macro.t()
  def spec(type, context, opts)
after
  defmacro sigil_t({:<<>>, _, [string]}, _) do
    string
    |> parse
    |> Macro.escape()
  end

  def parse(string) do
    case string do
      "u" <> _ ->
        Integer.parse(string)

      "i" <> _ ->
        Integer.parse(string)

      "f" <> _ ->
        Float.parse(string)

      "c_uint" <> _ ->
        Integer.parse(string)

      "[]" <> rest ->
        Slice.of(parse(rest))

      "[:0]" <> rest ->
        Slice.of(parse(rest), has_sentinel?: true)

      "[*]" <> rest ->
        Manypointer.of(parse(rest))

      "[*:0]" <> rest ->
        Manypointer.of(parse(rest), has_sentinel?: true)

      "[*c]" <> rest ->
        Cpointer.of(parse(rest))

      "?" <> rest ->
        Optional.of(parse(rest))

      "[" <> maybe_array ->
        case Elixir.Integer.parse(maybe_array) do
          {count, "]" <> rest} ->
            Array.of(parse(rest), count)

          {count, ":0]" <> rest} ->
            Array.of(parse(rest), count, has_sentinel?: true)

          _ ->
            raise "unknown type #{string}"
        end

      "?*.cimport" <> rest ->
        if String.ends_with?(rest, "struct_enif_environment_t") do
          Env
        else
          unknown =
            rest
            |> String.split(".")
            |> List.last()

          raise "unknown type #{unknown}"
        end
    end
  end

  @pointer_types ~w(array struct)

  def from_json(json, module) do
    case json do
      nil ->
        # only allow during documentation sema passes
        if module do
          raise CompileError, description: "zigler encountered anytype"
        else
          :anytype
        end

      %{"type" => "unusable:" <> typename} ->
        # only allow during documentation sema passes
        if module do
          raise CompileError, description: "zigler encountered the unusable type #{typename}"
        else
          String.to_atom(typename)
        end

      %{"type" => "bool"} ->
        Bool.from_json(json)

      %{"type" => "void"} ->
        :void

      %{"type" => "integer"} ->
        Integer.from_json(json)

      %{"type" => "enum"} ->
        Zig.Type.Enum.from_json(json, module)

      %{"type" => "float"} ->
        Float.from_json(json)

      %{
        "type" => "struct",
        "fields" => [%{"name" => "__payload"}, %{"name" => "__should_release"}]
      } ->
        Resource.from_json(json, module)

      %{"type" => "struct"} ->
        Struct.from_json(json, module)

      %{"type" => "array"} ->
        Array.from_json(json, module)

      %{"type" => "slice"} ->
        Slice.from_json(json, module)

      %{"type" => "pointer", "child" => child = %{"type" => type}} when type in @pointer_types ->
        child
        |> __MODULE__.from_json(module)
        |> Map.replace!(:mutable, true)

      %{"type" => "pointer", "child" => %{"type" => "unusable:anyopaque"}} ->
        :anyopaque_pointer

      %{"type" => "manypointer"} ->
        Manypointer.from_json(json, module)

      %{"type" => "cpointer"} ->
        Cpointer.from_json(json, module)

      %{"type" => "optional"} ->
        Optional.from_json(json, module)

      %{"type" => "error"} ->
        Error.from_json(json, module)

      %{"type" => "env"} ->
        :env

      %{"type" => "erl_nif_term"} ->
        :erl_nif_term

      %{"type" => "struct", "name" => "beam.term"} ->
        :term

      %{"type" => "pid"} ->
        :pid

      %{"type" => "port"} ->
        :port

      %{"type" => "term"} ->
        :term

      %{"type" => "e.ErlNifBinary"} ->
        :erl_nif_binary

      %{"type" => "e.ErlNifEvent"} ->
        :erl_nif_event

      %{"type" => "pointer", "child" => %{"type" => "e.ErlNifBinary"}} ->
        :erl_nif_binary_pointer

      %{"type" => "pointer", "child" => %{"type" => "builtin.StackTrace"}} ->
        :stacktrace
    end
  end

  def needs_make?(:erl_nif_term), do: false
  def needs_make?(:term), do: false
  def needs_make?(_), do: true

  # convenienece function
  def spec(atom) when is_atom(atom) do
    quote context: Elixir do
      unquote(atom)()
    end
  end

  # defaults

  def _default_payload_entry, do: ".{.error_info = &error_info},"
  def _default_return, do: "break :result_block beam.make(result, .{}).v;"
end

defimpl Zig.Type, for: Atom do
  def marshals_param?(_), do: false
  def marshals_return?(_), do: false

  def marshal_param(_, _, _, _), do: raise("unreachable")
  def marshal_return(_, _, _), do: raise("unreachable")

  def return_allowed?(type), do: type in ~w(term erl_nif_term pid void)a

  def render_return(:void), do: ""

  def spec(:void, :return, _), do: :ok

  def spec(:pid, _, _), do: Zig.Type.spec(:pid)

  def spec(term, _, _) when term in ~w(term erl_nif_term)a, do: Zig.Type.spec(:term)

  def missing_size?(_), do: false
end
