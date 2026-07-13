defmodule JSONCodec.MixProject do
  use Mix.Project

  def project do
    [
      app: :json_codec,
      version: "0.2.3",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      description: "Compile-time generated codecs for JSON-shaped Elixir structs",
      package: package(),
      source_url: "https://github.com/dannote/json_codec",
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:benchee, "~> 1.5", only: :dev, runtime: false},
      {:spectral, "~> 0.13.0", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Danila Poyarkov"],
      links: %{"GitHub" => "https://github.com/dannote/json_codec"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE SKILL.md)
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
