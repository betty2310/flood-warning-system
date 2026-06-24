#set page(width: 1400pt, height: 820pt, margin: 0pt, fill: rgb("#eef0f4"))
#set text(font: ("Arial", "Helvetica"), lang: "vi")
#let code = sys.inputs.at("code", default: "S?")
#let msg = sys.inputs.at("msg", default: "Ảnh chụp màn hình")
#align(center + horizon)[
  #block(
    width: 92%, height: 82%,
    stroke: (paint: rgb("#9aa0ad"), dash: "dashed", thickness: 3pt),
    radius: 12pt, inset: 36pt, fill: white,
  )[
    #align(center + horizon)[
      #text(size: 64pt, weight: "bold", fill: rgb("#c2c7d2"))[#code]
      #v(0.6em)
      #text(size: 30pt, fill: rgb("#5b6472"), weight: "bold")[#msg]
      #v(1.4em)
      #text(size: 18pt, fill: rgb("#98a0b0"))[Thay thế file PNG này bằng ảnh chụp thực tế (giữ nguyên tên file)]
    ]
  ]
]
