defmodule JSONCodec.SchemaTest do
  use ExUnit.Case, async: true

  defmodule Node do
    use JSONCodec
    defstruct [:name, children: [], indexed: %{}, parent: nil]

    @type t :: %__MODULE__{
            name: String.t(),
            children: [__MODULE__.t()],
            indexed: %{String.t() => __MODULE__.t()},
            parent: __MODULE__.t() | nil
          }
  end

  defmodule Left do
    use JSONCodec
    defstruct right: nil
    @type t :: %__MODULE__{right: JSONCodec.SchemaTest.Right.t() | nil}
  end

  defmodule Right do
    use JSONCodec
    defstruct left: nil
    @type t :: %__MODULE__{left: JSONCodec.SchemaTest.Left.t() | nil}
  end

  defmodule Forest do
    use JSONCodec
    defstruct nodes: [], indexed: %{}, odd: nil

    @type t :: %__MODULE__{
            nodes: [Node.t()],
            indexed: %{String.t() => Node.t()},
            odd: Node.t() | nil
          }
    codec(:odd, as: "a/b~c #%🦆")
  end

  defmodule Leaf do
    use JSONCodec
    defstruct [:value]
    @type t :: %__MODULE__{value: String.t()}
  end

  defmodule Pair do
    use JSONCodec
    defstruct [:first, :second]
    @type t :: %__MODULE__{first: Leaf.t(), second: Leaf.t()}
  end

  test "self recursion uses a reference to the containing schema" do
    schema = Node.schema()
    assert schema["properties"]["children"]["items"] == %{"$ref" => "#"}
    assert schema["properties"]["indexed"]["additionalProperties"] == %{"$ref" => "#"}
    assert schema["properties"]["parent"] == %{"$ref" => "#", "nullable" => true}
    assert schema["required"] == ["name"]
    assert Node.json_schema() == schema
    assert JSONCodec.Schema.type_schema(Node) == schema
    assert Jason.decode!(Jason.encode!(schema)) == schema
  end

  test "mutual recursion terminates regardless of which module is the root" do
    assert Left.schema()["properties"]["right"]["properties"]["left"] ==
             %{"$ref" => "#", "nullable" => true}

    assert Right.schema()["properties"]["left"]["properties"]["right"] ==
             %{"$ref" => "#", "nullable" => true}
  end

  test "nested recursion points to the correct array and map schemas" do
    schema = Forest.schema()
    nodes = schema["properties"]["nodes"]["items"]
    indexed = schema["properties"]["indexed"]["additionalProperties"]
    assert nodes["properties"]["children"]["items"]["$ref"] == "#/properties/nodes/items"

    assert indexed["properties"]["children"]["items"]["$ref"] ==
             "#/properties/indexed/additionalProperties"

    assert resolve(schema, nodes["properties"]["children"]["items"]["$ref"]) == nodes
    assert resolve(schema, indexed["properties"]["children"]["items"]["$ref"]) == indexed
  end

  test "reference paths escape JSON pointer tokens and URI fragments" do
    schema = Forest.schema()
    node = schema["properties"]["a/b~c #%🦆"]
    reference = node["properties"]["children"]["items"]["$ref"]
    assert reference == "#/properties/a~1b~0c%20%23%25%F0%9F%A6%86"
    assert resolve(schema, reference) == node
  end

  test "repeated acyclic modules stay inline and retain the existing schema shape" do
    schema = Pair.schema()

    assert schema == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["first", "second"],
             "properties" => %{"first" => Leaf.schema(), "second" => Leaf.schema()}
           }
  end

  test "recursive decoding remains independent of schema export" do
    assert %Node{children: [%Node{name: "child"}]} =
             Node.from_map!(%{"name" => "root", "children" => [%{"name" => "child"}]})
  end

  defp resolve(schema, "#" <> pointer) do
    pointer
    |> URI.decode()
    |> String.split("/", trim: true)
    |> Enum.reduce(schema, fn token, current ->
      key = token |> String.replace("~1", "/") |> String.replace("~0", "~")
      Map.fetch!(current, key)
    end)
  end
end
