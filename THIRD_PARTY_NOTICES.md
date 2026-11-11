# Third-party acknowledgments

## Tailscale update indicator

The circular up-arrow assets in
`Apps/Mac/Assets.xcassets/StatsUpdateAvailable.imageset` were extracted from
the `UpdateAvailable` image resource in Tailscale for macOS 1.104.1.
Copyright Tailscale Inc. Tailscale is not affiliated with Stats.

## Stats by Serhiy Mytrovtsiy (Exelban)

CPU monitoring and presentation draw from the open-source
[Stats project](https://github.com/exelban/stats), including Mach CPU tick
sampling, AppleARMPE core classification and CPU popup layout. Network collection
also adapts its SystemConfiguration physical-interface selection (including VPN
fallback) and its user-initiated CoreLocation authorization pattern for CoreWLAN
Wi-Fi names. Other collectors are integrated for this project's local
Mac-to-iPhone snapshot protocol. App artwork and user interfaces are independent.

The original Stats source is made available under the MIT License:

Copyright (c) 2019 Serhiy Mytrovtsiy

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
