defmodule Bench.IconifyLike.Hand.Icon do
  defstruct [:name, :body, width: 16, height: 16, left: 0, top: 0, rotate: 0, h_flip: false, v_flip: false]

  def from_map!(name, %{"body" => body} = map, defaults) do
    %__MODULE__{
      name: name,
      body: body,
      width: Map.get(map, "width", Map.get(defaults, "width", 16)),
      height: Map.get(map, "height", Map.get(defaults, "height", 16)),
      left: Map.get(map, "left", Map.get(defaults, "left", 0)),
      top: Map.get(map, "top", Map.get(defaults, "top", 0)),
      rotate: Integer.mod(Map.get(map, "rotate", Map.get(defaults, "rotate", 0)), 4),
      h_flip: Map.get(map, "hFlip", Map.get(defaults, "hFlip", false)),
      v_flip: Map.get(map, "vFlip", Map.get(defaults, "vFlip", false))
    }
  end
end

defmodule Bench.IconifyLike.Hand.Set do
  defstruct [:prefix, icons: %{}, width: 16, height: 16, left: 0, top: 0]

  def from_map!(%{"prefix" => prefix, "icons" => icons} = map) do
    defaults = Map.take(map, ["width", "height", "left", "top", "rotate", "hFlip", "vFlip"])

    %__MODULE__{
      prefix: prefix,
      icons: Map.new(icons, fn {name, data} -> {name, Bench.IconifyLike.Hand.Icon.from_map!(name, data, defaults)} end),
      width: Map.get(map, "width", 16),
      height: Map.get(map, "height", 16),
      left: Map.get(map, "left", 0),
      top: Map.get(map, "top", 0)
    }
  end
end

defmodule Bench.IconifyLike.Codec.Icon do
  use JSONCodec, case: :camel, fast_path: :json

  defstruct [:name, :body, width: 16, height: 16, left: 0, top: 0, rotate: 0, h_flip: false, v_flip: false]

  @type t :: %__MODULE__{
          name: String.t(),
          body: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          left: integer(),
          top: integer(),
          rotate: integer(),
          h_flip: boolean(),
          v_flip: boolean()
        }

  codec :rotate, transform: :normalize_rotate

  def normalize_rotate(value) when is_integer(value), do: Integer.mod(value, 4)
  def normalize_rotate(_value), do: 0
end

defmodule Bench.IconifyLike.Codec.Set do
  use JSONCodec, case: :camel, fast_path: :json

  defstruct [:prefix, icons: %{}, width: 16, height: 16, left: 0, top: 0]

  @type t :: %__MODULE__{
          prefix: String.t(),
          icons: %{String.t() => Bench.IconifyLike.Codec.Icon.t()},
          width: pos_integer(),
          height: pos_integer(),
          left: integer(),
          top: integer()
        }

  codec :icons, decode_values: :icon_value, values_source: :icon_defaults

  def icon_defaults(source), do: Map.take(source, ["left", "top", "width", "height", "rotate", "hFlip", "vFlip"])

  def icon_value(name, data, defaults) do
    %Bench.IconifyLike.Codec.Icon{
      name: name,
      body: Map.fetch!(data, "body"),
      width: Map.get(data, "width", Map.get(defaults, "width", 16)),
      height: Map.get(data, "height", Map.get(defaults, "height", 16)),
      left: Map.get(data, "left", Map.get(defaults, "left", 0)),
      top: Map.get(data, "top", Map.get(defaults, "top", 0)),
      rotate: Bench.IconifyLike.Codec.Icon.normalize_rotate(Map.get(data, "rotate", Map.get(defaults, "rotate", 0))),
      h_flip: Map.get(data, "hFlip", Map.get(defaults, "hFlip", false)),
      v_flip: Map.get(data, "vFlip", Map.get(defaults, "vFlip", false))
    }
  end
end

defmodule Bench.IconifyLike.Sample do
  def build(icon_count) do
    %{
      "prefix" => "demo",
      "width" => 24,
      "height" => 24,
      "icons" =>
        Map.new(1..icon_count, fn index ->
          name = "icon-#{index}"
          data = %{"body" => "<path d=\"M#{index} #{rem(index, 24)}h1v1z\"/>"}
          data = if rem(index, 5) == 0, do: Map.put(data, "width", 16 + rem(index, 16)), else: data
          data = if rem(index, 7) == 0, do: Map.put(data, "rotate", rem(index, 4)), else: data
          {name, data}
        end)
    }
  end
end

input = Bench.IconifyLike.Sample.build(1_000)
json = Jason.encode!(input)
decoded = Jason.decode!(json)

IO.puts("payload_bytes=#{byte_size(json)} icons=1000")

Benchee.run(
  %{
    "hand map->struct" => fn -> Bench.IconifyLike.Hand.Set.from_map!(decoded) end,
    "JSONCodec map->struct" => fn -> Bench.IconifyLike.Codec.Set.from_map!(decoded) end,
    "Jason.decode only" => fn -> Jason.decode!(json) end,
    "hand Jason+struct" => fn -> json |> Jason.decode!() |> Bench.IconifyLike.Hand.Set.from_map!() end,
    "JSONCodec Jason+struct" => fn -> Bench.IconifyLike.Codec.Set.decode!(json) end
  },
  time: 5,
  warmup: 2,
  memory_time: 1,
  print: [fast_warning: false]
)
