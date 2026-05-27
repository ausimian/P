defmodule M1Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M1 program from ExUnit. It takes the generated
  # mix lib (under ../PGenerated/Elixir) and the vendored p_runtime as path deps, exactly as
  # a real consumer would — except the deps are local paths rather than Hex packages.
  #
  # Run `p compile --mode elixir` in the parent directory first, then `mix test` here.
  def project do
    [
      app: :m1_harness,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # `override: true` makes this path dep win over the generated lib's `{:p_runtime, "~> 0.1"}`.
      {:p_runtime, path: Path.join(System.user_home!(), "Code/p_runtime"), override: true},
      {:m1_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
