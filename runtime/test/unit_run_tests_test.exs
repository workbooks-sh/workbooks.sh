defmodule Workbooks.UnitRunTestsTest do
  use ExUnit.Case, async: false
  alias Workbooks.Unit

  test "run_tests executes a test unit's cases against the unit under test" do
    dir = Path.join(System.tmp_dir!(), "wbrt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "score.work"), """
    # Score

    server :score do
      def score(x), do: x * 10
    end
    """)

    File.write!(Path.join(dir, "score_test.work"), """
    # Score tests

    test :score do
      test "scales by ten" do
        assert score(2) == 20
      end

      test "this one fails on purpose" do
        assert score(1) == 999
      end
    end
    """)

    result = Unit.run_tests(dir)

    assert result.passed == 1
    assert [{"score", msg}] = result.failed
    assert msg =~ "assertion failed"

    File.rm_rf!(dir)
  end
end
