defmodule JSONCodecTest do
  use ExUnit.Case, async: true

  defmodule FunctionID do
    use JSONCodec

    defstruct [:module, :function, :arity, :id]

    @type t :: %__MODULE__{
            module: String.t(),
            function: String.t(),
            arity: non_neg_integer(),
            id: String.t() | nil
          }

    computed(:id, fn function -> "#{function.module}.#{function.function}/#{function.arity}" end)
  end

  defmodule DataRef do
    use JSONCodec

    defstruct [:type, :function, :name, :index]

    @type t :: %__MODULE__{
            type: :argument | :return | :variable,
            function: FunctionID.t(),
            name: atom() | nil,
            index: non_neg_integer() | nil
          }

    codec(:name, atom: :unsafe)
  end

  defmodule DataFlow do
    use JSONCodec

    defstruct [:from, :to, through: [], variable_names: [], branch: nil]

    @type t :: %__MODULE__{
            from: DataRef.t(),
            to: DataRef.t(),
            through: [DataRef.t()],
            variable_names: [atom()],
            branch: :then | :else | :case | nil
          }

    codec(:variable_names, atom: :unsafe)
  end

  defmodule PackageManifest do
    use JSONCodec, case: :camel

    defstruct [:name, :version, dev_dependencies: %{}]

    @type t :: %__MODULE__{
            name: String.t(),
            version: String.t() | nil,
            dev_dependencies: %{String.t() => String.t()}
          }
  end

  defmodule FastPackageManifest do
    use JSONCodec, case: :camel, fast_path: :json

    defstruct [:name, :version, dev_dependencies: %{}]

    @type t :: %__MODULE__{
            name: String.t(),
            version: String.t() | nil,
            dev_dependencies: %{String.t() => String.t()}
          }
  end

  defmodule IconValue do
    use JSONCodec, fast_path: :json

    defstruct [:name, :body, width: 16]

    @type t :: %__MODULE__{name: String.t(), body: String.t(), width: pos_integer()}
  end

  defmodule IconSet do
    use JSONCodec, fast_path: :json

    defstruct [:prefix, icons: %{}]

    @type t :: %__MODULE__{prefix: String.t(), icons: %{String.t() => IconValue.t()}}

    codec(:icons, values: :icon_value, values_source: :icon_defaults)

    def icon_defaults(source), do: Map.take(source, ["width"])
    def icon_value(name, data, defaults), do: defaults |> Map.merge(data) |> Map.put("name", name)
  end

  defmodule DirectIconSet do
    use JSONCodec, fast_path: :json

    defstruct [:prefix, icons: %{}]

    @type t :: %__MODULE__{prefix: String.t(), icons: %{String.t() => IconValue.t()}}

    codec(:icons, decode_values: :icon_value, values_source: :icon_defaults)

    def icon_defaults(source), do: Map.take(source, ["width"])

    def icon_value(name, data, defaults) do
      %IconValue{
        name: name,
        body: Map.fetch!(data, "body"),
        width: Map.get(data, "width", Map.get(defaults, "width", 16))
      }
    end
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

  test "decodes JSON and aliases fields with camel case" do
    json = ~s({"name":"demo","devDependencies":{"jason":"~> 1.4"}})

    assert {:ok, manifest} = PackageManifest.decode(json)
    assert manifest.name == "demo"
    assert manifest.version == nil
    assert manifest.dev_dependencies == %{"jason" => "~> 1.4"}
  end

  test "fast JSON path decodes string keys and falls back for atom keys" do
    assert %FastPackageManifest{name: "demo", dev_dependencies: %{"jason" => "~> 1.4"}} =
             FastPackageManifest.from_map!(%{
               "name" => "demo",
               "devDependencies" => %{"jason" => "~> 1.4"}
             })

    assert %FastPackageManifest{name: "demo", dev_dependencies: %{"jason" => "~> 1.4"}} =
             FastPackageManifest.from_map!(%{
               name: "demo",
               dev_dependencies: %{"jason" => "~> 1.4"}
             })
  end

  test "fast JSON path decodes map values through local callback" do
    assert %IconSet{icons: %{"home" => %IconValue{name: "home", body: "<path/>", width: 24}}} =
             IconSet.from_map!(%{
               "prefix" => "demo",
               "width" => 16,
               "icons" => %{"home" => %{"body" => "<path/>", "width" => 24}}
             })

    assert %IconSet{icons: %{"home" => %IconValue{name: "home", body: "<path/>", width: 16}}} =
             IconSet.from_map!(%{
               "prefix" => "demo",
               "width" => 16,
               "icons" => %{"home" => %{"body" => "<path/>"}}
             })
  end

  test "fast JSON path supports directly decoded map values" do
    assert %DirectIconSet{
             icons: %{"home" => %IconValue{name: "home", body: "<path/>", width: 16}}
           } =
             DirectIconSet.from_map!(%{
               "prefix" => "demo",
               "width" => 16,
               "icons" => %{"home" => %{"body" => "<path/>"}}
             })
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
