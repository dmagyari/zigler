defmodule Zig.Nif.Concurrency do
  @moduledoc """
  behaviour module which describes the interface for "plugins" which
  generate concurrency-specific code.
  """

  alias Zig.Nif

  @callback render_elixir(Nif.t()) :: Macro.t()
  @callback render_erlang(Nif.t()) :: term
  @callback render_zig(Nif.t()) :: iodata

  @type concurrency :: :synchronous | :dirty_cpu | :dirty_io
  @type table_entry ::
          {name :: atom, arity :: non_neg_integer, function_pointer :: atom,
           bootstrap :: concurrency}

  @doc """
  returns "table_entry" tuples which are then used to generate the nif table.
  if a nif function needs multiple parts, for example, for concurrency
  management, then multiple entries should be returned.
  """
  @callback table_entries(Nif.t()) :: [table_entry]
  @callback resources(Nif.t()) :: [{:root, atom}]
end