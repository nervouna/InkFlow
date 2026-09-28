import InkFlowRime
import SwiftUI

struct PersonalLearningSettingsView: View {
    @State private var entries: [IFEngine.PersonalLearningEntry] = []
    @State private var source = IFEngine.PersonalLearningEntry.Source.english
    @State private var query = ""
    @State private var loaded = false
    @State private var message: String?
    @State private var pendingDeletion: IFEngine.PersonalLearningEntry?
    @State private var confirmDelete = false
    @State private var undo: IFEngine.PersonalLearningUndo?

    private var filtered: [IFEngine.PersonalLearningEntry] {
        entries.filter { $0.source == source && (query.isEmpty
            || $0.text.localizedCaseInsensitiveContains(query) || $0.code.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("个人学习管理").font(.headline)
            Text("个人英文用于键盘候选，包含键盘选择和语音纠正学习的词条。语音别名仅用于替换语音识别结果。删除别名不会删除对应的个人英文。")
                .foregroundStyle(.secondary)
            Picker("来源", selection: $source) {
                Text("个人英文").tag(IFEngine.PersonalLearningEntry.Source.english)
                Text("语音纠正别名").tag(IFEngine.PersonalLearningEntry.Source.voice)
            }.pickerStyle(.segmented)
            HStack {
                TextField("搜索词条或编码", text: $query)
                    .accessibilityIdentifier("learning.search")
                Button("刷新", action: reload).accessibilityIdentifier("learning.refresh")
            }
            if loaded {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "此来源暂无个人学习条目。" : "没有匹配的条目。")
                        .foregroundStyle(.secondary)
                } else {
                    List(filtered) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.text).textSelection(.enabled)
                                Text("\(entry.code) · 学习 \(entry.commits) 次").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) { pendingDeletion = entry; confirmDelete = true }
                                .accessibilityLabel("删除 \(entry.text)，编码 \(entry.code)")
                        }
                    }.frame(minHeight: 150, maxHeight: 280)
                }
            }
            if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("learning.status") }
            if undo != nil {
                Button("撤销上次删除", action: restore).accessibilityIdentifier("learning.undo")
            }
            Text("撤销会恢复条目并增加一次学习，排序可能重新计算。继续输入、学习、清除或再次删除后，原撤销可能失效；重启 InkFlow 后不保留撤销。内置英文仍可出现在候选中。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .confirmationDialog("删除此学习条目？", isPresented: $confirmDelete) {
            if let entry = pendingDeletion {
                Button("删除", role: .destructive) { remove(entry) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let entry = pendingDeletion {
                Text("\(entry.code) → \(entry.text)。仅删除当前来源的条目，不影响中文学习或自定义短语。")
            }
        }
    }

    private func reload() {
        do {
            entries = try IFEngine.personalLearningEntries()
            loaded = true
            message = nil
        } catch { entries = []; loaded = false; message = description(error) }
    }

    private func remove(_ entry: IFEngine.PersonalLearningEntry) {
        pendingDeletion = nil
        do {
            undo = try IFEngine.deletePersonalLearning(entry)
            reload()
            if loaded { message = "条目已删除，下次输入或语音识别时生效。" }
        } catch { undo = nil; reload(); message = description(error) }
    }

    private func restore() {
        guard let undo else { return }
        do {
            try IFEngine.undoPersonalLearning(undo)
            self.undo = nil
            reload()
            if loaded { message = "条目已恢复，学习次数增加一次。" }
        } catch {
            if error as? IFEngine.PersonalLearningError != .busy { self.undo = nil }
            reload()
            message = description(error)
        }
    }

    private func description(_ error: Error) -> String {
        switch error as? IFEngine.PersonalLearningError {
        case .busy: "请结束当前输入，稍候几秒后刷新或重试。"
        case .conflict: "学习记录已变化，未执行此操作。请刷新后重试。"
        case .tooLarge: "条目数量或学习次数超过本次操作上限，未执行操作。"
        default: "无法读取或更新学习记录，请刷新后重试。"
        }
    }
}
