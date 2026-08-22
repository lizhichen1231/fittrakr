// 【新 UI】数据层 —— 设计稿 _days/_clips/_setDefs/_capParams 的逐字移植。
// ★当前为设计稿同款假数据(与浏览器原型逐条一致,便于对版);
//   真实素材库/录制接线是后续任务卡,本文件届时换成真数据源,接口不变。

import Foundation

struct MTDay {
    let d: String, wd: String, cat: String, n: Int, lost: Int, seed: String
}

enum MTSegKind { case dark, lit, gap }

struct MTSeg {
    let kind: MTSegKind
    let frac: Double      // 占全片比例
    let zoom: Double      // lit 段倍率(厚度=倍率)
}

struct MTClip {
    let dur: String
    let secs: Int
    let parts: [MTSeg]
    let imgURL: URL?
}

func mtDays() -> [MTDay] {
    [
        MTDay(d: "8.18", wd: "周二", cat: "力量训练", n: 12, lost: 0, seed: "mytrack-a2"),
        MTDay(d: "8.16", wd: "周日", cat: "街舞", n: 18, lost: 2, seed: "mytrack-b7"),
        MTDay(d: "8.14", wd: "周五", cat: "有氧拳击", n: 9, lost: 0, seed: "mytrack-c1"),
        MTDay(d: "8.11", wd: "周二", cat: "力量训练", n: 15, lost: 0, seed: "mytrack-d4"),
        MTDay(d: "8.07", wd: "周五", cat: "街舞", n: 21, lost: 3, seed: "mytrack-e9"),
        MTDay(d: "8.03", wd: "周一", cat: "瑜伽", n: 7, lost: 1, seed: "mytrack-f3"),
    ]
}

func mtCats(_ days: [MTDay]) -> [String] {
    var seen = Set<String>(), out = ["全部"]
    for d in days where !seen.contains(d.cat) { seen.insert(d.cat); out.append(d.cat) }
    return out
}

/// 一条带子:下沿对齐、上沿随倍率起伏;跟丢=断口(设计稿伪随机公式逐字移植)
func mtClips(_ day: MTDay) -> [MTClip] {
    var lostSet = Set<Int>()
    for k in 0..<day.lost { lostSet.insert((k * 5 + 2) % day.n) }
    return (0..<day.n).map { i in
        let sec = 22 + ((i * 53 + day.n * 11) % 88)
        let dur = "\(sec / 60):" + String(format: "%02d", sec % 60)
        let m = 6 + (i % 3)
        let raw = (0..<m).map { j in 0.6 + Double((i * 29 + j * 17) % 80) / 100 }
        let tot = raw.reduce(0, +)
        let zs = (0..<m).map { j -> Double in
            let r = (i * 13 + j * 23) % 6
            return r < 2 ? 1 : r < 4 ? 1.75 : r < 5 ? 2.5 : 3
        }
        let lead = Double((i * 37 + 13) % 14) / 100
        let gw = lostSet.contains(i) ? 0.055 + Double((i * 7) % 4) / 100 : 0
        let gapAfter = lostSet.contains(i) ? 1 + ((i * 7) % (m - 2)) : -1
        let avail = 1 - (lead > 0.04 ? lead : 0) - gw
        var parts: [MTSeg] = []
        if lead > 0.04 { parts.append(MTSeg(kind: .dark, frac: lead, zoom: 1)) }
        for (j, w) in raw.enumerated() {
            parts.append(MTSeg(kind: .lit, frac: w / tot * avail, zoom: zs[j]))
            if j == gapAfter { parts.append(MTSeg(kind: .gap, frac: gw, zoom: 1)) }
        }
        return MTClip(dur: dur, secs: sec, parts: parts,
                      imgURL: URL(string: "https://picsum.photos/seed/\(day.seed)-c\(i)/720/1280"))
    }
}

// ── 设置页定义(设计稿 _setDefs)──

struct MTSettingRow {
    let k: String, name: String, defVal: String, desc: String
    var opts: [String]? = nil
    var toggle: Bool = false
    var danger: Bool = false
    var act: Bool = false     // 动作行(清理):选中不改值
}

struct MTSettingGroup { let name: String; let rows: [MTSettingRow] }

func mtSettingGroups(cats: [String]) -> [MTSettingGroup] {
    [
        MTSettingGroup(name: "拍摄", rows: [
            MTSettingRow(k: "q", name: "录制画质", defVal: "4K · 30", desc: "录得越高文件越大,4K 每分钟约 400 MB", opts: ["4K · 60", "4K · 30", "1080 · 60", "1080 · 30"]),
            MTSettingRow(k: "dim", name: "录制时屏幕变暗", defVal: "开", desc: "人离开后屏幕调暗,减少发热和耗电", toggle: true),
            MTSettingRow(k: "torch", name: "跟丢时闪手电筒", defVal: "开", desc: "跟丢较久时闪一下提醒,恢复时闪两下", toggle: true),
            MTSettingRow(k: "flashT", name: "闪灯触发时长", defVal: "3 秒", desc: "跟丢超过这个时长才闪", opts: ["2 秒", "3 秒", "5 秒", "8 秒"]),
            MTSettingRow(k: "mem", name: "记住上次拍摄参数", defVal: "开", desc: "关闭则每次进相机回到自动", toggle: true),
        ]),
        MTSettingGroup(name: "默认偏好", rows: [
            MTSettingRow(k: "defCat", name: "默认分类", defVal: "力量训练", desc: "新素材默认归入,拍前可改", opts: Array(cats.dropFirst())),
            MTSettingRow(k: "cd", name: "默认倒计时", defVal: "5 秒", desc: "按下快门后的等待时间", opts: ["3 秒", "5 秒", "10 秒"]),
            MTSettingRow(k: "haptic", name: "触觉反馈", defVal: "开", desc: "拨盘、切换镜头时轻微震动", toggle: true),
        ]),
        MTSettingGroup(name: "导出", rows: [
            MTSettingRow(k: "autoExp", name: "拍完自动导出到相册", defVal: "关", desc: "开启后每条素材录完即存入相册", toggle: true),
            MTSettingRow(k: "trim", name: "导出时剪掉跟丢段", defVal: "关", desc: "默认导出完整素材", toggle: true),
            MTSettingRow(k: "codec", name: "编码格式", defVal: "HEVC", desc: "HEVC 文件更小,H.264 兼容性更好", opts: ["HEVC", "H.264"]),
        ]),
        MTSettingGroup(name: "素材", rows: [
            MTSettingRow(k: "space", name: "已用空间", defVal: "1.8 GB", desc: "其中已导出 0.9 GB 可清理", opts: ["清理已导出的 0.9 GB"], danger: true, act: true),
            MTSettingRow(k: "unexp", name: "未导出", defVal: "7 条", desc: "这些素材只存在 app 内,尚未备份"),
            MTSettingRow(k: "cats", name: "分类管理", defVal: "4 个分类", desc: "重命名、删除、排序"),
        ]),
        MTSettingGroup(name: "关于", rows: [
            MTSettingRow(k: "ver", name: "版本", defVal: "1.0 (12)", desc: ""),
            MTSettingRow(k: "perm", name: "权限", defVal: "", desc: "相机 · 麦克风 · 相册"),
            MTSettingRow(k: "fb", name: "反馈", defVal: "", desc: ""),
        ]),
    ]
}

// ── 拍摄页参数转盘(设计稿 _capParams/_capDefaults + 值说明)──

struct MTCapParam { let name: String; let vals: [String]; let descs: [String] }

func mtCapParams() -> [MTCapParam] {
    [
        MTCapParam(name: "ISO 上限", vals: ["自动", "800", "1600", "3200"],
                   descs: ["由系统根据光线决定", "日光下干净", "室内够用", "光线很差时用,噪点明显"]),
        MTCapParam(name: "白平衡", vals: ["自动", "日光", "白炽灯", "荧光灯"],
                   descs: ["", "户外", "暖光室内", "冷光室内"]),
        MTCapParam(name: "曝光补偿", vals: ["−2", "−1", "0", "+1", "+2"],
                   descs: ["偏暗", "偏暗", "", "偏亮", "偏亮"]),
        MTCapParam(name: "对焦", vals: ["自动", "锁定"],
                   descs: ["", "固定距离时画面不反复对焦"]),
        MTCapParam(name: "倒计时", vals: ["关", "3 秒", "5 秒", "10 秒"],
                   descs: ["", "按下后走到位再开始", "按下后走到位再开始", "按下后走到位再开始"]),
        MTCapParam(name: "麦克风", vals: ["开", "关"],
                   descs: ["", "不录音"]),
    ]
}

func mtCapDefaults() -> [Int] { [0, 0, 2, 0, 0, 0] }

/// 主题背景图(素材库/设置/回看/拍摄预览共用,设计稿 picsum id/1018)
let mtThemeURL = URL(string: "https://picsum.photos/id/1018/1080/1920")
