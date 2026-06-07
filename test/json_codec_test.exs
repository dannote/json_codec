defmodule JSONCodecTest do
  use ExUnit.Case, async: true

  defmodule FunctionID do
    use JSONCodec

    field(:module, :string)
    field(:function, :string)
    field(:arity, :non_neg_integer)
    computed(:id, fn function -> "#{function.module}.#{function.function}/#{function.arity}" end)
  end

  defmodule DataRef do
    use JSONCodec

    field(:type, {:enum, [:argument, :return, :variable]})
    field(:function, FunctionID)
    field(:name, :atom, optional: true, atom: :unsafe)
    field(:index, :non_neg_integer, optional: true)
  end

  defmodule DataFlow do
    use JSONCodec

    field(:from, DataRef)
    field(:to, DataRef)
    field(:through, {:list, DataRef}, default: [])
    field(:variable_names, {:list, :atom}, default: [], atom: :unsafe)
    field(:branch, {:nullable, {:enum, [:then, :else, :case]}}, default: nil)
  end

  defmodule PackageManifest do
    use JSONCodec

    field(:name, :string)
    field(:version, :string, optional: true)
    field(:dev_dependencies, {:map, :string, :string}, json: "devDependencies", default: %{})
  end

  test "decodes nested structs with computed fields" do
    map = %{
      "from" => %{
        "type" => "argument",
        "function" => %{"module" => "A", "function" => "foo", "arity" => 2},
        "name" => "input",
        "index" => 0
      },
      "to" => %{
        "type" => "return",
        "function" => %{"module" => "A", "function" => "foo", "arity" => 2}
      },
      "through" => [],
      "variable_names" => ["acc", "result"],
      "branch" => "then"
    }

    assert %DataFlow{} = flow = DataFlow.from_map!(map)
    assert flow.from.type == :argument
    assert flow.from.name == :input
    assert flow.from.function.id == "A.foo/2"
    assert flow.variable_names == [:acc, :result]
    assert flow.branch == :then
  end

  test "decodes JSON and aliases fields" do
    json = ~s({"name":"demo","devDependencies":{"jason":"~> 1.4"}})

    assert {:ok, manifest} = PackageManifest.decode(json)
    assert manifest.name == "demo"
    assert manifest.version == nil
    assert manifest.dev_dependencies == %{"jason" => "~> 1.4"}
  end

  test "returns structured errors" do
    assert {:error, error} = PackageManifest.from_map(%{"version" => "1.0.0"})
    assert %JSONCodec.Error{path: [:name], reason: :missing_required_field} = error
  end

  test "exports JSON Schema-compatible maps" do
    assert %{
             "type" => "object",
             "required" => ["name"],
             "properties" => %{"devDependencies" => %{"type" => "object"}}
           } = PackageManifest.json_schema()
  end
end
