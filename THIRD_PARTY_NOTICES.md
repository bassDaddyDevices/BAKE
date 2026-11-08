# Third-Party Notices

BAKE ships only permissively licensed third-party code (MIT, BSD, Apache-2.0, zlib, or similar).
Copyleft licenses (GPL, LGPL, AGPL) are not permitted in any target.

Each dependency is listed below with its license text when it is added.

## Signalsmith Stretch

Time-stretching and pitch-shifting for the Stretch node.
https://github.com/Signalsmith-Audio/signalsmith-stretch — commit a670068d9aeb64913331d5cc29337b19a457a7df
Vendored at `BakeCore/Sources/BakeDSP/Vendor/signalsmith-stretch/`.

**Modified:** `signalsmith-stretch.h` carries two BAKE patches (marked `BAKE patch` in the source):
phase-aligned interpolation of the per-bin phase advance when pitch-shifting, which removes a
pitch bias of up to tens of cents on shifted partials (time-stretching without transposition is
unchanged); and an explicit cast of the seed to the random engine's seed type, which silences an
implicit-narrowing warning without changing behaviour.

```
MIT License

Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Signalsmith Linear

FFT and STFT used by Signalsmith Stretch.
https://github.com/Signalsmith-Audio/linear — commit 146b26f91b48835d665fa0498d64d9617818d27a
Vendored at `BakeCore/Sources/BakeDSP/Vendor/signalsmith-linear/` (`stft.h` and `fft.h` only).

```
MIT License

Copyright (c) 2025 Signalsmith Audio

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
