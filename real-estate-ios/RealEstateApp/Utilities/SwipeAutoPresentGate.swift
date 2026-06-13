//
//  SwipeAutoPresentGate.swift
//  RealEstateApp
//
//  スワイプセッション画面を「起動／フォアグラウンド復帰のたびに強制表示」する
//  挙動をやめ、自動表示は1日1回までに抑制するための純粋な判定ロジック。
//  手動導線（TodayView の「未評価N件をスワイプ」カード）はこのゲートを通らず
//  常に開けるため、ここでの抑制は自動表示のみに効く。
//

import Foundation

enum SwipeAutoPresentGate {
    /// 自動表示の重複判定に使う「暦日」キー。
    /// 和暦端末でも安定させるため内部は常にグレゴリオ暦で組み立て、
    /// タイムゾーンのみ引数カレンダー（既定は端末ローカル）から継承する。
    /// これにより端末のカレンダー設定（和暦↔西暦）を変えても保存値と
    /// 不整合を起こさない（CLAUDE.md の DateFormatter ルールと同じ思想）。
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// スワイプ画面を自動表示すべきか。
    /// - Parameters:
    ///   - pendingCount: 未評価の対象件数（0 なら出さない）
    ///   - lastPresentedDay: 前回自動表示した日キー（未表示は空文字）
    ///   - today: 現在の日キー
    /// - Returns: 対象があり、かつ今日まだ自動表示していなければ true（=1日1回まで）
    static func shouldPresent(pendingCount: Int, lastPresentedDay: String, today: String) -> Bool {
        pendingCount > 0 && lastPresentedDay != today
    }
}
