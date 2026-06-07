defmodule Bench.Hand.FunctionID do
  defstruct [:module, :function, :arity, :id]

  def from_map!(%{"module" => module, "function" => function, "arity" => arity}) do
    %__MODULE__{
      module: module,
      function: function,
      arity: arity,
      id: "#{module}.#{function}/#{arity}"
    }
  end
end

defmodule Bench.Hand.DataRef do
  defstruct [:type, :function, :name, :index]

  def from_map!(%{"type" => type, "function" => function} = map) do
    %__MODULE__{
      type: String.to_existing_atom(type),
      function: Bench.Hand.FunctionID.from_map!(function),
      name: optional_atom(Map.get(map, "name")),
      index: Map.get(map, "index")
    }
  end

  defp optional_atom(nil), do: nil
  defp optional_atom(value), do: String.to_atom(value)
end

defmodule Bench.Hand.DataFlow do
  defstruct [:from, :to, through: [], variable_names: [], branch: nil]

  def from_map!(%{"from" => from, "to" => to} = map) do
    %__MODULE__{
      from: Bench.Hand.DataRef.from_map!(from),
      to: Bench.Hand.DataRef.from_map!(to),
      through: Enum.map(Map.get(map, "through", []), &Bench.Hand.DataRef.from_map!/1),
      variable_names: Enum.map(Map.get(map, "variable_names", []), &String.to_atom/1),
      branch: optional_existing_atom(Map.get(map, "branch"))
    }
  end

  defp optional_existing_atom(nil), do: nil
  defp optional_existing_atom(value), do: String.to_existing_atom(value)
end

defmodule Bench.Hand.Manifest do
  defstruct data_flows: []

  def from_map!(%{"data_flows" => flows}),
    do: %__MODULE__{data_flows: Enum.map(flows, &Bench.Hand.DataFlow.from_map!/1)}
end

defmodule Bench.Codec.FunctionID do
  use JSONCodec, fast_path: :json

  defstruct [:module, :function, :arity, :id]

  @type t :: %__MODULE__{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          id: String.t() | nil
        }

  computed(:id, fn function -> "#{function.module}.#{function.function}/#{function.arity}" end)
end

defmodule Bench.Codec.DataRef do
  use JSONCodec, fast_path: :json

  defstruct [:type, :function, :name, :index]

  @type t :: %__MODULE__{
          type: :argument | :return | :variable,
          function: Bench.Codec.FunctionID.t(),
          name: atom() | nil,
          index: non_neg_integer() | nil
        }

  codec(:name, atom: :unsafe)
end

defmodule Bench.Codec.DataFlow do
  use JSONCodec, fast_path: :json

  defstruct [:from, :to, through: [], variable_names: [], branch: nil]

  @type t :: %__MODULE__{
          from: Bench.Codec.DataRef.t(),
          to: Bench.Codec.DataRef.t(),
          through: [Bench.Codec.DataRef.t()],
          variable_names: [atom()],
          branch: :then | :else | :case | nil
        }

  codec(:variable_names, atom: :unsafe)
end

defmodule Bench.Codec.Manifest do
  use JSONCodec, fast_path: :json

  defstruct data_flows: []

  @type t :: %__MODULE__{data_flows: [Bench.Codec.DataFlow.t()]}
end

defmodule Bench.Spectral.FunctionID do
  use Spectral
  defstruct [:module, :function, :arity, :id]

  @type t :: %__MODULE__{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          id: String.t() | nil
        }
end

defmodule Bench.Spectral.DataRef do
  use Spectral
  defstruct [:type, :function, :name, :index]

  @type t :: %__MODULE__{
          type: :argument | :return | :variable,
          function: Bench.Spectral.FunctionID.t(),
          name: atom() | nil,
          index: non_neg_integer() | nil
        }
end

defmodule Bench.Spectral.DataFlow do
  use Spectral
  defstruct [:from, :to, through: [], variable_names: [], branch: nil]

  @type t :: %__MODULE__{
          from: Bench.Spectral.DataRef.t(),
          to: Bench.Spectral.DataRef.t(),
          through: [Bench.Spectral.DataRef.t()],
          variable_names: [atom()],
          branch: :then | :else | :case | nil
        }
end

defmodule Bench.Spectral.Manifest do
  use Spectral
  defstruct data_flows: []
  @type t :: %__MODULE__{data_flows: [Bench.Spectral.DataFlow.t()]}
end

defmodule Bench.Sample do
  def build(flow_count) do
    functions =
      for i <- 1..max(flow_count, 3) do
        mod = "Program#{rem(i, 20)}.Module#{rem(i, 7)}"
        fun = "function_#{i}"
        arity = rem(i, 5)
        %{"module" => mod, "function" => fun, "arity" => arity}
      end

    ref = fn i, type ->
      %{
        "type" => type,
        "function" => Enum.at(functions, rem(i, length(functions))),
        "name" => "var_#{rem(i, 30)}",
        "index" => rem(i, 4)
      }
    end

    %{
      "data_flows" =>
        for i <- 1..flow_count do
          %{
            "from" => ref.(i, "argument"),
            "to" => ref.(i + 1, "variable"),
            "through" => [ref.(i + 2, "variable"), ref.(i + 3, "return")],
            "variable_names" => ["x#{rem(i, 10)}", "acc", "result"],
            "branch" => Enum.at(["then", "else", "case", nil], rem(i, 4))
          }
        end
    }
  end
end

for atom_name <-
      ["argument", "return", "variable", "then", "else", "case", "acc", "result"] ++
        Enum.map(0..30, &"var_#{&1}") ++ Enum.map(0..10, &"x#{&1}") do
  String.to_atom(atom_name)
end

input = Bench.Sample.build(250)
json = Jason.encode!(input)
decoded = Jason.decode!(json)
Application.put_env(:spectra, :module_types_cache, :persistent)
Spectral.decode!(decoded, Bench.Spectral.Manifest, :t, :json, [:pre_decoded])

IO.puts("payload_bytes=#{byte_size(json)} flows=250")

Benchee.run(
  %{
    "hand map->struct" => fn -> Bench.Hand.Manifest.from_map!(decoded) end,
    "JSONCodec map->struct" => fn -> Bench.Codec.Manifest.from_map!(decoded) end,
    "Jason.decode only" => fn -> Jason.decode!(json) end,
    "hand Jason+struct" => fn -> json |> Jason.decode!() |> Bench.Hand.Manifest.from_map!() end,
    "JSONCodec Jason+struct" => fn -> Bench.Codec.Manifest.decode!(json) end,
    "Spectral pre_decoded" => fn ->
      Spectral.decode!(decoded, Bench.Spectral.Manifest, :t, :json, [:pre_decoded])
    end,
    "Spectral native JSON" => fn -> Spectral.decode!(json, Bench.Spectral.Manifest, :t, :json) end
  },
  time: 5,
  warmup: 2,
  memory_time: 1,
  print: [fast_warning: false]
)
