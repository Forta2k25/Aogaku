import {Box, imageConnectorFeatures} from "./visualRouter";
// Cheap raster text-band estimates, not OCR and not an Evidence source. Only a
// separated connector between substantial text bands can enable the fast path.
// All other layouts still use the existing OCR-assisted Router.
export function localConnectorSignal(data: Uint8ClampedArray, width: number, height: number) {
  const rows = Array.from({length: height}, () => ({left: width, right: -1, ink: 0}));
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const i = (y * width + x) * 4;
    if (data[i+3] > 80 && .2126*data[i]+.7152*data[i+1]+.0722*data[i+2] < 205) {
      rows[y].left = Math.min(rows[y].left, x); rows[y].right = Math.max(rows[y].right, x); rows[y].ink++;
    }
  }
  const boxes: Box[] = [];
  for (let y = 0; y < height;) {
    if (!rows[y].ink) { y++; continue; }
    const start = y; let end = y, left = width, right = -1, gap = 0;
    for (; y < height; y++) {
      if (rows[y].ink) { gap=0; end=y; left=Math.min(left,rows[y].left); right=Math.max(right,rows[y].right); }
      else if (++gap > 2) break;
    }
    const h = end-start+1, w = right-left+1;
    if (h >= 6 && h <= Math.min(width,height)*.08 && w >= width*.08 && w/h >= 3) {
      boxes.push({x:left/width,y:start/height,w:w/width,h:h/height});
    }
  }
  const connectors = imageConnectorFeatures(data,width,height,boxes).connectorComponents;
  return {connectorComponents: boxes.length >= 2 ? connectors : 0, estimatedTextBands: boxes.length};
}
