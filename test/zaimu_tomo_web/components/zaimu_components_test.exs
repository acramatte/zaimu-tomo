defmodule ZaimuTomoWeb.ZaimuComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Statements
  alias ZaimuTomoWeb.ZaimuComponents

  describe "status_pill/1" do
    test "renders a human label and pill class for every derived statement status" do
      expected = %{
        processing: {"pill processing", "Processing"},
        ready: {"pill posted", "Read"},
        failed: {"pill failed", "Failed"},
        stalled: {"pill", "Processing stalled"}
      }

      statuses = Statements.statuses()
      assert MapSet.new(statuses) == MapSet.new(Map.keys(expected))

      for status <- statuses do
        html = render_component(&ZaimuComponents.status_pill/1, status: Atom.to_string(status))

        refute html =~ ">#{status}<",
               "expected a dedicated human label for status #{inspect(status)}, got: #{html}"

        {pill_class, label} = Map.fetch!(expected, status)
        assert html =~ ~s(class="#{pill_class}")
        assert html =~ ">#{label}</span>"
      end
    end
  end

  describe "account_type_label/1" do
    test "formats every financial account type as a capitalized human label" do
      types = FinancialAccount.account_types()
      assert Enum.any?(types)

      for type <- types do
        label = ZaimuComponents.account_type_label(type)

        assert label != ""
        assert label =~ ~r/\A[A-Z]/
        refute label =~ "_"
      end

      assert ZaimuComponents.account_type_label(:current) == "Current account"
    end

    test "raises FunctionClauseError for unknown account types" do
      Enum.each([:checking, :unknown], fn unknown ->
        assert_raise FunctionClauseError, fn ->
          ZaimuComponents.account_type_label(unknown)
        end
      end)
    end
  end
end
