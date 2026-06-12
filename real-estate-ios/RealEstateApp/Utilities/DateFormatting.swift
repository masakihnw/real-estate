//
//  DateFormatting.swift
//  RealEstateApp
//
//  共有 DateFormatter（static let + en_US_POSIX、和暦端末対策）。
//  DateFormatter の生成は高コストなため、View の body 評価ごとに
//  生成しないよう必ずここで共有する（CLAUDE.md ルール）。
//

import Foundation

enum DateFormatting {
    /// ISO 8601（マイクロ秒付き。Python isoformat() 対応）
    static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO 8601（秒精度）
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO 8601 文字列をパース（マイクロ秒付き/なしの両対応）
    static func parseISO8601(_ string: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: string) ?? iso8601.date(from: string)
    }

    /// 表示用 "yyyy/MM/dd HH:mm:ss"（JST 固定）
    static let displayDateTimeSecondsJST: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f
    }()

    /// 表示用 "yyyy/MM/dd HH:mm"（端末ローカル時刻）
    static let displayDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()
}
