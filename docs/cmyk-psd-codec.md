# Private native-CMYK PSD serialization

This private codec is preparation for native CMYK export. It does not expose
an export command or change the existing RGB-to-CMYK PSD path.

The stream contains PSD version 1, four process channels, CMYK mode, 8-bit or
16-bit integer depth, an exact ICC resource, and uncompressed planar samples.
No layer, alpha, resolution or other metadata resources are emitted by this
primitive. These choices follow the [Adobe file-format specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/).
The dimensions are limited to 30,000 pixels and the complete stream to
2,147,483,647 bytes, within Adobe's [PSD size limit](https://helpx.adobe.com/photoshop/desktop/save-and-export/export-files-to-different-formats/photoshop-file-formats-overview.html).

Glims ink intensity and PSD's inverted CMYK samples share the same convention:
zero is full ink and the maximum is paper. U8 bytes remain unchanged; U16
samples change only from host byte order to big-endian. This is established by
pinned GIMP `7addd2b77efb798bbdc4d2fb082e786a48478ced`,
`plug-ins/file-psd/psd-export.c` at its `cmyk u8`/`cmyk u16` format selection and
channel packing, plus babl `4abcea43550699e0c93e6f154c44d68822e62753`,
`babl/base/model-cmyk.c`'s inverted encoding. The existing independent PSD CMYK
export tests likewise compare `255 - file_sample` with LCMS coverage.

Source reads stay within one row and request at most 4,096 samples. A typed
U16 buffer guarantees source alignment, with byte access and in-place endian
conversion avoiding a second image buffer. The caller owns the source/profile
lifetime and must keep the specification and ICC bytes immutable during the
synchronous call. No source samples are converted through RGB.

Structural profile checks cover the bounded payload, declared length, signatures
and supported profile classes. Full color-transform validation remains the
caller's responsibility. Preflight rejects invalid specifications and excessive
file sizes before any callbacks. Read and write failures stop immediately with
distinct status codes. Partial output remains possible after an I/O failure;
the future file-export caller must write privately and atomically replace its
destination only after complete success.

Float quantization, PSB, compression, resolution/metadata resources, native file
admission, destination replacement, UI and numeric-preserving import remain
separate work. Do not interpret upstream GIMP's ordinary CMYK-to-RGB import as
a raw-channel round trip.

The independent fixture passes 315 checks in both optimized and ASan/UBSan
builds. It checks literal headers, exact ICC bytes and padding, every sample
across long/chunked rows, both integer depths, preflight size boundaries and
immediate callback-failure propagation. Source review found no confirmed
important findings. The native adapter matrix, actual-file integration and
latest CI remain pending. Reproduce the portable checks with:

```sh
bash scripts/test-cmyk-psd-codec.sh
```
