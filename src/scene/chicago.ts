export const CHICAGO = '"ChicagoFLFRegular", "Silkscreen", monospace';

/** Draw now, then redraw once the Chicago webfont is ready so canvas text never sticks on a fallback. */
export function whenChicago(draw: () => void) {
  draw();
  document.fonts?.load(`48px ${CHICAGO}`).then(draw, () => {});
}
