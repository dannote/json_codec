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

    codec(:name, atom: {:enum, [:input, :acc, :result]})
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

    codec(:variable_names, atom: {:enum, [:acc, :result]})
  end

  defmodule FeatureFlag do
    use JSONCodec

    defstruct [:name, enabled: false, state: :active]

    @type t :: %__MODULE__{name: String.t(), enabled: boolean(), state: atom()}
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

  defmodule StrictChild do
    use JSONCodec, strict: true, fast_path: :json

    defstruct [:name]

    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule StrictParent do
    use JSONCodec, strict: true, fast_path: :json

    defstruct [:child]

    @type t :: %__MODULE__{child: StrictChild.t()}
  end

  defmodule CastOnlyStruct do
    defstruct [:value]
    @type t :: %__MODULE__{value: String.t()}
  end

  defmodule CastOnlyPayload do
    use JSONCodec, strict: true, fast_path: :json

    defstruct [:wrapped]

    @type t :: %__MODULE__{wrapped: CastOnlyStruct.t()}

    codec(:wrapped, cast: :wrap)

    def wrap(value), do: %CastOnlyStruct{value: value}
  end

  defmodule CastEvent do
    use JSONCodec, case: :camel, fast_path: :json

    defstruct [:name, :created_at, :normalized_name]

    @type t :: %__MODULE__{
            name: String.t(),
            created_at: DateTime.t(),
            normalized_name: String.t()
          }

    codec(:created_at, as: "createdAtMs", cast: :datetime_ms)
    codec(:normalized_name, cast: &String.trim/1, transform: :upcase)

    def datetime_ms(milliseconds), do: DateTime.from_unix!(milliseconds, :millisecond)
    def upcase(value), do: String.upcase(value)
  end

  defmodule GuardedDateTimeCast do
    use JSONCodec, strict: true, fast_path: :json

    defstruct [:expires_at]

    @type t :: %__MODULE__{expires_at: DateTime.t()}

    codec(:expires_at, as: "expires", cast: :expires_datetime)

    def expires_datetime(expires) when is_integer(expires) do
      expires |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
    end
  end

  defmodule StrictPackageManifest do
    use JSONCodec, case: :camel, strict: true, fast_path: :json

    defstruct [:name, :version, dev_dependencies: %{}]

    @type t :: %__MODULE__{
            name: String.t(),
            version: String.t() | nil,
            dev_dependencies: %{String.t() => String.t()}
          }
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

    assert %PackageManifest{dev_dependencies: %{}} = struct(PackageManifest)
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

  test "strict mode rejects atom-key maps while decoding JSON strings" do
    assert {:ok, %StrictPackageManifest{name: "demo"}} =
             StrictPackageManifest.decode(~s({"name":"demo"}))

    assert_raise JSONCodec.Error, ~r/non_string_key/, fn ->
      StrictPackageManifest.from_map!(%{name: "demo"})
    end

    assert {:error, %JSONCodec.Error{reason: :non_string_key}} =
             StrictPackageManifest.from_map(%{name: "demo"})
  end

  test "strict nested JSONCodec modules defined in the same source decode from maps" do
    assert %StrictParent{child: %StrictChild{name: "demo"}} =
             StrictParent.from_map!(%{"child" => %{"name" => "demo"}})
  end

  test "cast can produce declared non-JSONCodec structs without requiring from_map" do
    assert %CastOnlyPayload{wrapped: %CastOnlyStruct{value: "demo"}} =
             CastOnlyPayload.from_map!(%{"wrapped" => "demo"})
  end

  test "cast runs before type decode and transform runs after type decode" do
    created_at_ms = 1_782_703_591_000

    assert %CastEvent{} =
             event =
             CastEvent.from_map!(%{
               "name" => "demo",
               "createdAtMs" => created_at_ms,
               "normalizedName" => "  hello  "
             })

    assert event.created_at == DateTime.from_unix!(created_at_ms, :millisecond)
    assert event.normalized_name == "HELLO"
  end

  test "guarded cast callbacks do not create unreachable generated type checks" do
    expires = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_unix(:millisecond)

    assert %GuardedDateTimeCast{expires_at: %DateTime{} = expires_at} =
             GuardedDateTimeCast.from_map!(%{"expires" => expires})

    assert DateTime.to_unix(expires_at, :millisecond) == expires
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

  test "fast JSON path preserves missing required field errors" do
    assert {:error, error} = FastPackageManifest.from_map(%{"version" => "1.0.0"})
    assert %JSONCodec.Error{path: [:name], reason: :missing_required_field} = error
  end

  test "fast JSON path preserves type errors" do
    assert_raise JSONCodec.Error, ~r/\.name: invalid_type/, fn ->
      FastPackageManifest.from_map!(%{"name" => 123})
    end
  end

  test "map value decoding rejects invalid key types" do
    assert_raise JSONCodec.Error, ~r/\.icons: invalid_type/, fn ->
      IconSet.from_map!(%{"prefix" => "demo", "icons" => %{home: %{"body" => "<path/>"}}})
    end
  end

  test "decode_values callback errors pass through" do
    assert_raise KeyError, fn ->
      DirectIconSet.from_map!(%{"prefix" => "demo", "icons" => %{"home" => %{}}})
    end
  end

  test "encodes booleans as booleans and atoms as strings" do
    assert FeatureFlag.to_map(%FeatureFlag{name: "demo", enabled: true, state: :active}) == %{
             "name" => "demo",
             "enabled" => true,
             "state" => "active"
           }

    assert JSONCodec.to_map(%{ok: true, error: false, state: :done}) == %{
             "ok" => true,
             "error" => false,
             "state" => "done"
           }
  end

  test "dumps JSONCodec structs using JSON field names" do
    manifest = %PackageManifest{name: "demo", dev_dependencies: %{"jason" => "~> 1.4"}}

    assert PackageManifest.dump(manifest) == %{
             "name" => "demo",
             "version" => nil,
             "devDependencies" => %{"jason" => "~> 1.4"}
           }

    assert JSONCodec.dump(%{manifest: manifest, ok: true, state: :done}) == %{
             "manifest" => %{
               "name" => "demo",
               "version" => nil,
               "devDependencies" => %{"jason" => "~> 1.4"}
             },
             "ok" => true,
             "state" => "done"
           }
  end

  test "exports JSON Schema-compatible maps" do
    assert %{
             "type" => "object",
             "required" => ["name"],
             "properties" => %{"devDependencies" => %{"type" => "object"}}
           } = PackageManifest.schema()

    assert PackageManifest.json_schema() == PackageManifest.schema()
    assert JSONCodec.schema(PackageManifest) == PackageManifest.schema()
    assert JSONCodec.json_schema(PackageManifest) == PackageManifest.schema()
  end
end
