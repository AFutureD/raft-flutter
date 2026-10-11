Test-only CJK fallback fixture, not an application asset.

Derived from Noto Sans SC variable font, weight 400, retaining only 中文日本語测试汉字. Family metadata renamed to Raft IME CJK Fixture. Original glyph outlines and font metrics retained. SIL Open Font License in LICENSE.txt.

Upstream: https://github.com/notofonts/noto-cjk/blob/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/Variable/TTF/Subset/NotoSansSC-VF.ttf
Original SHA-256: d68bafcb48a2707749396aa12bbbd833cb70401f3a9a689fd2902c7e0d295964
Subset SHA-256: 7e7236cc1b80a4a68cece7c5695d9d26856aa70f1c8ec157281c3856d1e3b19d
Generated with fontTools variable-font instancing and subset (all names retained, then family/style/unique/PostScript names renamed). No Latin glyphs retained, so loading it as the CJK fallback cannot replace the real bundled Latin fonts in the raster regression.
