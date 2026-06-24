defmodule Nexus.WashyConformanceTest do
  @moduledoc """
  The Wave-3 forcing function (wb-vlxn): run REAL, unmodified npm packages on Washy and assert their
  behavior. This is the empirical gate that turns "we think it works" into "package X passes" — and it
  earns its keep: the very first run (lodash) surfaced the IEEE-754 float gap (wb-8mdz.3, now fixed).

  Fixtures are vendored under test/conformance/ (the real single-file UMD builds). Each runs through the
  Sandbox interp lane exactly as a guest would, with a battery of operations checked against expected
  output. Add packages here as they're brought up; every failure → a precise bd issue under the Node epic.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"
  @lodash "test/conformance/lodash-4.17.21.js"

  defp run_js(js) do
    Sandbox.run_command({:interp, @qjs, js}, "", fuel: 2_000_000_000_000, timeout_ms: 120_000)
  end

  test "real lodash 4.17.21 loads and a battery of operations is correct" do
    if File.exists?(@qjs) and File.exists?(@lodash) do
      driver = """
      var _ = (typeof module!=='undefined' && module.exports && module.exports.VERSION) ? module.exports : _;
      var out=[];
      function t(name, got, want){ out.push((JSON.stringify(got)===JSON.stringify(want)?'PASS ':'FAIL ')+name); }
      t('VERSION', _.VERSION, '4.17.21');
      t('chunk', _.chunk([1,2,3,4],2), [[1,2],[3,4]]);
      t('map', _.map([1,2,3], function(x){return x*2;}), [2,4,6]);
      t('filter', _.filter([1,2,3,4], function(x){return x%2==0;}), [2,4]);
      t('reduce', _.reduce([1,2,3], function(a,b){return a+b;},0), 6);
      t('uniq', _.uniq([1,1,2,3,3]), [1,2,3]);
      t('flatten', _.flatten([1,[2,[3]]]), [1,2,[3]]);
      t('groupBy', _.groupBy([1,2,3,4], function(x){return x%2;}), {0:[2,4],1:[1,3]});
      t('keyBy', _.keyBy([{id:'a'},{id:'b'}], 'id'), {a:{id:'a'},b:{id:'b'}});
      t('sortBy', _.sortBy([3,1,2]), [1,2,3]);
      t('merge', _.merge({a:1},{b:2}), {a:1,b:2});
      t('cloneDeep', _.cloneDeep({a:{b:1}}), {a:{b:1}});
      t('get', _.get({a:{b:{c:7}}},'a.b.c'), 7);
      t('set', _.set({},'a.b',5), {a:{b:5}});
      t('pick', _.pick({a:1,b:2,c:3},['a','c']), {a:1,c:3});
      t('omit', _.omit({a:1,b:2,c:3},['b']), {a:1,c:3});
      t('camelCase', _.camelCase('foo bar'), 'fooBar');
      t('kebabCase', _.kebabCase('fooBar'), 'foo-bar');
      t('capitalize', _.capitalize('hello'), 'Hello');
      t('range', _.range(4), [0,1,2,3]);
      t('template', _.template('hi <%= n %>')({n:'x'}), 'hi x');
      Javy.IO.writeSync(1,new TextEncoder().encode(out.join('\\n')));
      """

      js = File.read!(@lodash) <> "\n" <> driver
      assert {:ok, out} = run_js(js)
      results = String.split(out, "\n", trim: true)
      fails = Enum.filter(results, &String.starts_with?(&1, "FAIL"))

      assert fails == [], "lodash conformance failures: #{inspect(fails)}"
      assert length(results) >= 20
    else
      IO.puts("\n[skip] qjs-run.wasm or lodash fixture missing")
    end
  end
end
