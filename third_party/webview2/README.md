# WebView2 SDK Vendor Layout

The Windows system web engine embeds the OS WebView2 runtime. The interface header and the loader library that discovers the installed runtime come from the WebView2 SDK NuGet package and are vendored here so a repo checkout builds the real embedded-WebView Windows host with no extra fetch step.

Vendored from the `Microsoft.Web.WebView2` NuGet package, version `1.0.2903.40` (package sha256 `ef128016dd1e51c59178c827ed5b8aa3322c57afa8675d930f8109505542ad74`), under the package's BSD-style license (`LICENSE.txt`, kept verbatim alongside the files it covers):

```text
third_party/webview2/
  LICENSE.txt                 package LICENSE.txt, verbatim
  include/WebView2.h          build/native/include/WebView2.h, verbatim
  x64/WebView2Loader.dll      build/native/x64/WebView2Loader.dll, verbatim
  arm64/WebView2Loader.dll    build/native/arm64/WebView2Loader.dll, verbatim
```

`include/EventToken.h` is a first-party compatibility shim (see its header comment), not a package file.

The build adds `include/` to the include path of the Windows host and stages the architecture's `WebView2Loader.dll` next to the app executable; the host loads it at runtime to locate the installed WebView2 runtime (preinstalled on stock Windows 11; on older machines the Evergreen runtime installer provides it). Apps that never load a WebView run fine without either piece.

To update: download a newer `Microsoft.Web.WebView2` package from NuGet, replace the files listed above verbatim, and record the new version and package sha256 here.
