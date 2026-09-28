defmodule JSONCodec.Schema do
  @moduledoc """
  Behaviour for modules that provide their own JSON Schema.

  Every `JSONCodec` module implements it. Other modules implement it to give
  codec fields that reference them a schema:

      defmodule Money do
        @behaviour JSONCodec.Schema

        @impl true
        def json_schema, do: %{"type" => "string", "pattern" => "^\\\\d+\\\\.\\\\d{2}$"}
      end

  Referenced modules that implement neither get an empty schema.
  """

  @doc "Returns a JSON Schema-compatible map describing this module's JSON form."
  @callback json_schema() :: map()
end
