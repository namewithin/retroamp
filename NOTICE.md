# Notices

Retroamp source code and project-created assets are distributed under the MIT license in LICENSE.

Classic Winamp 2 sprite coordinates were checked against Webamp's
`packages/webamp/js/skinSprites.ts`:
https://github.com/captbaritone/webamp

The upstream MIT notice is preserved, unchanged, in
`BundleResources/Webamp-MIT.txt`, and is included in built app bundles.

No Webamp runtime or original Winamp bitmap skin is bundled. The source for
rendering, controls, audio and window management is Swift/AppKit, with a small bounded C PCM ring. The original
icon was drawn programmatically for this project; the default player interface
was developed in AppKit with an AI-generated visual concept as a reference.

The project license does not cover third-party skins imported by users or
confer rights to Winamp/Google names and branding. macOS frameworks, zlib and
Google Chrome (used only by the optional fresh Google sign-in flow) are external dependencies supplied under their own terms.
