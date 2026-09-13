defmodule JSONCodec.UnionTest do
  use ExUnit.Case, async: true

  defmodule Generic do
    use JSONCodec
    defstruct [:value, :nullable, :status, :mixed, :flag, items: [], values: %{}]

    @type t :: %__MODULE__{
            value: String.t() | integer(),
            nullable: String.t() | integer() | nil,
            status: :string | :integer,
            mixed: :unset | integer(),
            flag: true | false,
            items: [String.t() | integer()],
            values: %{String.t() => String.t() | integer()}
          }
  end

  defmodule Fast do
    use JSONCodec, strict: true, fast_path: :json
    defstruct [:value, :nullable, :status, :mixed, :flag, items: [], values: %{}]

    @type t :: %__MODULE__{
            value: String.t() | integer(),
            nullable: String.t() | integer() | nil,
            status: :string | :integer,
            mixed: :unset | integer(),
            flag: true | false,
            items: [String.t() | integer()],
            values: %{String.t() => String.t() | integer()}
          }
  end

  defmodule Text do
    use JSONCodec
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Count do
    use JSONCodec
    defstruct [:count]
    @type t :: %__MODULE__{count: integer()}
  end

  defmodule ObjectUnion do
    use JSONCodec
    defstruct [:value]
    @type t :: %__MODULE__{value: Text.t() | Count.t()}
  end

  defmodule BrokenCallback do
    use JSONCodec
    defstruct [:value]
    @type t :: %__MODULE__{value: String.t()}
    codec(:value, transform: :explode)
    def explode(_value), do: raise(ArgumentError, "callback failed")
  end

  defmodule CallbackUnion do
    use JSONCodec
    defstruct [:value]
    @type t :: %__MODULE__{value: BrokenCallback.t() | String.t()}
  end

  defp payload do
    %{
      "value" => "hello",
      "nullable" => nil,
      "status" => "string",
      "mixed" => "unset",
      "flag" => true
    }
  end

  for module <- [Generic, Fast] do
    test "#{inspect(module)} decodes primitives, nullable unions, and literal enums" do
      module = unquote(module)

      for value <- ["hello", "integer", "string", 42] do
        decoded = module.from_map!(Map.put(payload(), "value", value))
        assert decoded.value == value
        assert decoded.nullable == nil
        assert decoded.status == :string
        assert decoded.mixed == :unset
        assert decoded.flag == true
      end

      decoded =
        module.decode!(
          Jason.encode!(%{
            payload()
            | "nullable" => 12,
              "mixed" => 7,
              "status" => "integer",
              "flag" => false
          })
        )

      assert decoded.nullable == 12
      assert decoded.mixed == 7
      assert decoded.status == :integer
      assert decoded.flag == false
      assert module.from_map!(%{payload() | "nullable" => "text"}).nullable == "text"
    end

    test "#{inspect(module)} exports type unions rather than enum markers" do
      properties = unquote(module).schema()["properties"]
      union = %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      assert properties["value"] == union
      assert properties["nullable"] == Map.put(union, "nullable", true)
      assert properties["status"] == %{"type" => "string", "enum" => ["string", "integer"]}
      assert properties["flag"] == %{"anyOf" => [%{"const" => true}, %{"const" => false}]}
    end

    test "#{inspect(module)} validates unions in lists and maps with useful paths" do
      module = unquote(module)

      decoded =
        module.from_map!(
          Map.merge(payload(), %{"items" => [1, "two"], "values" => %{"x" => 1, "y" => "two"}})
        )

      assert decoded.items == [1, "two"]
      assert decoded.values == %{"x" => 1, "y" => "two"}

      assert {:error,
              %JSONCodec.Error{path: [:items, 1], expected: {:one_of, [:string, :integer]}}} =
               module.from_map(Map.put(payload(), "items", [1, true]))

      assert {:error, %JSONCodec.Error{path: [:values, "bad"]}} =
               module.from_map(Map.put(payload(), "values", %{"bad" => []}))

      for value <- [true, 1.5, nil, %{}, []] do
        assert {:error,
                %JSONCodec.Error{path: [:value], expected: {:one_of, [:string, :integer]}}} =
                 module.from_map(Map.put(payload(), "value", value))
      end
    end
  end

  test "remote codec types are alternatives, not module-name enum literals" do
    assert %ObjectUnion{value: %Text{text: "hello"}} =
             ObjectUnion.from_map!(%{"value" => %{"text" => "hello"}})

    assert %ObjectUnion{value: %Count{count: 3}} =
             ObjectUnion.from_map!(%{"value" => %{"count" => 3}})

    assert %{"anyOf" => [text, count]} = ObjectUnion.schema()["properties"]["value"]
    assert text == Text.schema()
    assert count == Count.schema()
  end

  test "union fallback does not swallow arbitrary callback exceptions" do
    assert_raise ArgumentError, "callback failed", fn ->
      CallbackUnion.from_map!(%{"value" => %{"value" => "boom"}})
    end
  end
end
