import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import test from "node:test"
import {tooltipLeft} from "../../../assets/js/balance_trend_tooltip.js"

test("hidden balance tooltips cannot widen the page before interaction", () => {
  const css = readFileSync(new URL("../../../assets/css/zaimutomo.css", import.meta.url), "utf8")
  const rule = selector => css.split(`${selector} {`)[1]?.split("}")[0]

  assert.ok(rule(".balance-trend-chart .line-point .line-tooltip").includes("display: none;"))
  assert.ok(rule(".balance-trend-chart .line-point:focus-visible .line-tooltip").includes("display: block;"))
})

test("centers a readable tooltip when it fits", () => {
  assert.equal(tooltipLeft({left: 492, width: 16}, 320, 1024), -152)
})

test("keeps a left-edge tooltip inside the viewport", () => {
  assert.equal(tooltipLeft({left: 4, width: 16}, 320, 1024), 12)
})

test("keeps a right-edge tooltip inside the viewport", () => {
  assert.equal(tooltipLeft({left: 1000, width: 16}, 320, 1024), -312)
})

test("keeps tooltips outside the sidebar on narrow screens", () => {
  for (const left of [90, 160, 280]) {
    const offset = tooltipLeft({left, width: 16}, 220, 320, 68)
    assert.equal(left + offset, 84)
  }
})

test("fits a viewport-wide mobile tooltip without squeezing it to the plot width", () => {
  for (const left of [4, 160, 280]) {
    const offset = tooltipLeft({left, width: 16}, 288, 320)
    assert.equal(left + offset, 16)
  }
})
