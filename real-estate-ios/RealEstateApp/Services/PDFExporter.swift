//
//  PDFExporter.swift
//  RealEstateApp
//
//  物件比較シートを A4 PDF として生成する。
//

import UIKit

enum PDFExporter {
    static func generateComparisonPDF(listings: [Listing]) -> Data? {
        let pageWidth: CGFloat = 595.28  // A4
        let pageHeight: CGFloat = 841.89
        let margin: CGFloat = 40

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { context in
            context.beginPage()

            let titleFont = UIFont.boldSystemFont(ofSize: 18)
            let headerFont = UIFont.boldSystemFont(ofSize: 10)
            let bodyFont = UIFont.systemFont(ofSize: 9)

            var y: CGFloat = margin

            // Title
            let title = "物件比較シート"
            let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont]
            title.draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttr)
            y += 30

            // Date
            let dateStr = "作成日: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none))"
            let dateAttr: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.gray]
            dateStr.draw(at: CGPoint(x: margin, y: y), withAttributes: dateAttr)
            y += 25

            // Table
            let colWidth = (pageWidth - margin * 2) / CGFloat(listings.count + 1)
            let rowHeight: CGFloat = 22

            let fields: [(String, (Listing) -> String)] = [
                ("物件名", { $0.name }),
                ("価格", { $0.priceMan.map { "\($0)万円" } ?? "-" }),
                ("面積", { $0.areaM2.map { String(format: "%.1f㎡", $0) } ?? "-" }),
                ("間取り", { $0.layout ?? "-" }),
                ("住所", { $0.address ?? "-" }),
                ("徒歩", { $0.walkMin.map { "\($0)分" } ?? "-" }),
                ("築年", { $0.builtStr ?? "-" }),
                ("階数", { $0.floorPosition.map { "\($0)階" } ?? "-" }),
                ("管理費", { $0.managementFee.map { "¥\($0)" } ?? "-" }),
                ("修繕積立金", { $0.repairReserveFund.map { "¥\($0)" } ?? "-" }),
                ("m²単価", {
                    guard let p = $0.priceMan, let a = $0.areaM2, a > 0 else { return "-" }
                    return String(format: "%.0f万/㎡", Double(p) / a)
                }),
            ]

            // Header row
            for (col, listing) in listings.enumerated() {
                let x = margin + colWidth * CGFloat(col + 1)
                let text = String(listing.name.prefix(12))
                text.draw(in: CGRect(x: x, y: y, width: colWidth - 4, height: rowHeight), withAttributes: [.font: headerFont])
            }
            y += rowHeight

            // Draw line
            let linePath = UIBezierPath()
            linePath.move(to: CGPoint(x: margin, y: y))
            linePath.addLine(to: CGPoint(x: pageWidth - margin, y: y))
            UIColor.gray.setStroke()
            linePath.stroke()
            y += 4

            // Data rows
            for (label, getter) in fields {
                // Label
                label.draw(in: CGRect(x: margin, y: y, width: colWidth - 4, height: rowHeight), withAttributes: [.font: headerFont])

                // Values
                for (col, listing) in listings.enumerated() {
                    let x = margin + colWidth * CGFloat(col + 1)
                    let value = getter(listing)
                    value.draw(in: CGRect(x: x, y: y, width: colWidth - 4, height: rowHeight), withAttributes: [.font: bodyFont])
                }
                y += rowHeight
            }
        }

        return data
    }
}
