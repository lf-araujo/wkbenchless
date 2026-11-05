## Included by synedit.nim: BMP fallback for images pixie cannot load. wkbenchless only; kept out of
## that file so a sync with focim stays small.

proc writeBmp24(path: string; img: pixie.Image) =
  ## Encode `img` as an uncompressed 24-bit BI_RGB BMP (bottom-up, BGR, rows
  ## padded to 4 bytes) -- exactly the shape the drivers' decodeBmp reads. Alpha
  ## is assumed already composited (the caller flattens over white).
  let w = img.width; let h = img.height
  let rowSize = ((w * 3 + 3) div 4) * 4
  let dataSize = rowSize * h
  let fileSize = 54 + dataSize
  var b = newSeq[byte](fileSize)
  template put16(off, v) = (b[off] = byte(v and 0xFF); b[off+1] = byte((v shr 8) and 0xFF))
  template put32(off, v) =
    b[off] = byte(v and 0xFF); b[off+1] = byte((v shr 8) and 0xFF)
    b[off+2] = byte((v shr 16) and 0xFF); b[off+3] = byte((v shr 24) and 0xFF)
  b[0] = byte('B'); b[1] = byte('M')
  put32(2, fileSize); put32(10, 54)                 # file header: size, pixel offset
  put32(14, 40); put32(18, w); put32(22, h)          # BITMAPINFOHEADER, +h = bottom-up
  put16(26, 1); put16(28, 24); put32(30, 0)          # planes=1, bpp=24, BI_RGB
  put32(34, dataSize); put32(38, 2835); put32(42, 2835)
  for row in 0 ..< h:
    let srcRow = h - 1 - row                          # bottom-up
    var o = 54 + row * rowSize
    let base = srcRow * w
    for x in 0 ..< w:
      let px = img.data[base + x]                      # ColorRGBX (composited, a=255)
      b[o] = px.b; b[o+1] = px.g; b[o+2] = px.r        # BMP stores BGR
      o += 3
  writeFile(path, b)

proc toLoadableBmp(src: string): string =
  ## The driver decodes BMP; for any other format (PNG, JPG, GIF, …) decode with
  ## pixie (pure Nim -- no ImageMagick) and cache a 24-bit BMP with transparency
  ## flattened over white, keyed by path + size so it converts once. Returns ""
  ## if the source is missing or cannot be decoded.
  if not fileExists(src): return ""
  if src.toLowerAscii.endsWith(".bmp"): return src
  var key = src
  try: key.add ":" & $getFileSize(src) except CatchableError: discard
  let cacheDir = getCacheDir() / "wkbenchless" / "imgcache"
  let outp = cacheDir / (toHex(hash(key).uint64) & ".bmp")
  if fileExists(outp): return outp
  try: createDir(cacheDir) except CatchableError: discard
  try:
    let img = pixie.readImage(src)                     # PNG/JPG/GIF/BMP/QOI/PPM/SVG
    let flat = pixie.newImage(img.width, img.height)    # composite over white
    pixie.fill(flat, pixie.rgba(255, 255, 255, 255))
    pixie.draw(flat, img)
    writeBmp24(outp, flat)
    if fileExists(outp): return outp
  except CatchableError:
    discard
  result = ""
