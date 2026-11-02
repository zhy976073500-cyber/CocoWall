//
//  ContentView.swift
//  TendiesPreview (Phase 0 probe)
//
//  Deliberately un-productised UI (SPEC): an import button, the layer
//  canvas, state buttons for EVERY enumerated state (24 chips for
//  Cubes, horizontally scrollable grid), the two scripted actions, and
//  the scrolling diagnostics panel. Nothing else.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: PreviewViewModel
    @State private var showImporter = false

    private var importTypes: [UTType] {
        // .tendies has no system UTI; accept it via the exported type
        // declared in Info.plist, plus generic zip/archive/data so the
        // picker never greys a real package out.
        [UTType(filenameExtension: "tendies") ?? .data, .zip, .archive, .data]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                canvas
                controls
                statesSection
                diagnostics
            }
            .padding(12)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { vm.importFrom(url: url) }
            case .failure(let error):
                vm.log("文件选择失败: \(error.localizedDescription)")
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("壁纸预览探针").font(.headline)
                Text(vm.packageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showImporter = true
            } label: {
                Label("导入 .tendies", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isBusy)
        }
    }

    private var canvas: some View {
        LayerCanvasView(vm: vm)
            .aspectRatio(vm.canvasSize.width / max(vm.canvasSize.height, 1),
                         contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                vm.playUnlockScript()
            } label: {
                Label("开屏→解锁", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.stateNames.isEmpty)

            Button {
                vm.runSwitchSelfTest()
            } label: {
                Label("连切 20 次自检", systemImage: "repeat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.stateNames.count < 2)
        }
    }

    private var statesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("状态（\(vm.stateNames.count)）")
                .font(.subheadline.bold())
            if vm.stateNames.isEmpty {
                Text("导入后这里列出包内全部状态，点按切换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(vm.stateNames, id: \.self) { name in
                        Button {
                            vm.applyState(named: name)
                        } label: {
                            Text(name)
                                .font(.caption2)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.bordered)
                        .tint(vm.currentStateName == name ? .green : .accentColor)
                    }
                }
            }
            if let current = vm.currentStateName {
                Text("当前: \(current)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("诊断").font(.subheadline.bold())
            Text(vm.diagnosticText)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
