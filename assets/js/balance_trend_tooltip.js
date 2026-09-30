export function tooltipLeft(point, width, viewportWidth, contentLeft = 0) {
  const margin = 16
  const centered = point.left + point.width / 2 - width / 2
  return Math.max(contentLeft + margin, Math.min(centered, viewportWidth - width - margin)) - point.left
}

export default {
  mounted() {
    this.positionTooltip = ({target}) => {
      const point = target.closest(".balance-trend-point")
      if (!point || !this.el.contains(point)) return

      const tooltip = point.querySelector(".line-tooltip")
      const main = this.el.closest(".main")
      const contentLeft = Math.max(0, main?.getBoundingClientRect().left ?? 0)
      tooltip.style.maxWidth = `${Math.max(0, window.innerWidth - contentLeft - 32)}px`
      const left = tooltipLeft(point.getBoundingClientRect(), tooltip.offsetWidth, window.innerWidth, contentLeft)
      tooltip.style.left = `${left}px`
    }
    this.repositionTooltip = () => {
      const point = this.el.querySelector(".balance-trend-point:hover, .balance-trend-point:focus")
      if (point) this.positionTooltip({target: point})
    }
    this.el.addEventListener("mouseover", this.positionTooltip)
    this.el.addEventListener("focusin", this.positionTooltip)
    window.addEventListener("resize", this.repositionTooltip)
    this.resizeObserver = new ResizeObserver(this.repositionTooltip)
    this.resizeObserver.observe(this.el)
  },
  updated() {
    this.repositionTooltip()
  },
  destroyed() {
    this.el.removeEventListener("mouseover", this.positionTooltip)
    this.el.removeEventListener("focusin", this.positionTooltip)
    window.removeEventListener("resize", this.repositionTooltip)
    this.resizeObserver.disconnect()
  },
}
