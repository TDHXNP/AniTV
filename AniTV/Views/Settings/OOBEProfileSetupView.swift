//
//  OOBEProfileSetupView.swift
//  AniTV
//
//  Created by Codex on 2026/8/8.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct OOBEProfileSetupView: View {
    let isAuthenticating: Bool
    let statusMessage: String
    let lanEntryURL: String
    let lanServiceStatus: String
    let createGuestAction: () -> Void
    let connectBangumiAction: () -> Void
    var onAppearAction: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    private var shouldShowStatusBanner: Bool {
        if isAuthenticating {
            return true
        }
        let trimmed = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "尚未登录 Bangumi。"
    }

    private var isFailureStatus: Bool {
        statusMessage.contains("失败") || statusMessage.contains("失效") || statusMessage.contains("请先填写") || statusMessage.contains("无法") || statusMessage.contains("没有")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        Color(red: 0.04, green: 0.05, blue: 0.09)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                HStack(alignment: .top, spacing: max(proxy.size.width * 0.15, 180)) {
                    leftColumn(maxWidth: min(proxy.size.width * 0.34, 470))
                    rightColumn(maxWidth: min(proxy.size.width * 0.42, 620))
                }
                .frame(maxWidth: 1580, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 76)
                .padding(.top, proxy.size.height * 0.105)
            }
        }
        .onAppear {
            onAppearAction?()
        }
        .onExitCommand {
            onDismiss?()
        }
    }

    @ViewBuilder
    private func leftColumn(maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("AniTV")
                    .font(.system(size: 66, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.bottom, 42)

                Text("连接至 Bangumi")
                    .font(.system(size: 45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)

                Text("通过 Bangumi 账号，你可以管理番剧收藏和收视进度。")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(-2)
                    .fixedSize(horizontal: false, vertical: true)

                if shouldShowStatusBanner {
                    HStack(spacing: 12) {
                        if isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: isFailureStatus ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(isFailureStatus ? Color.orange : Color.green)
                        }

                        Text(statusMessage)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isFailureStatus ? Color.orange.opacity(0.18) : Color.white.opacity(0.12))
                    )
                    .padding(.top, 24)
                }
            }

            Spacer(minLength: 32)

            VStack(alignment: .leading, spacing: 18) {
                OOBEActionButton(
                    title: isAuthenticating ? "正在登录 Bangumi…" : "用 Apple 设备登录",
                    systemImage: "ipad.landscape.and.iphone",
                    action: connectBangumiAction
                )
                .disabled(isAuthenticating)
                .frame(width: 420)

                OOBEActionButton(
                    title: "作为游客继续",
                    systemImage: "person.2",
                    action: createGuestAction
                )
                .disabled(isAuthenticating)
                .frame(width: 420)
            }
            .padding(.bottom, 90)
        }
        .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rightColumn(maxWidth: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 0) {
            OOBEQRCodeView(urlString: lanEntryURL)
                .padding(.top, 6)

            VStack(spacing: 14) {
                Text("扫描二维码或访问")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))

                Text(lanEntryURL.isEmpty ? "等待局域网地址" : lanEntryURL)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)

                if lanEntryURL.isEmpty, !lanServiceStatus.isEmpty {
                    Text(lanServiceStatus)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 54)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: maxWidth)
    }
}

private struct OOBEActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))

                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.horizontal, 18)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct OOBEQRCodeView: View {
    let urlString: String

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if !urlString.isEmpty, let image = makeQRCodeImage(from: urlString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 500, height: 500)
                    .padding(36)
                    .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: 572, height: 572)
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 64, weight: .medium))
                                .foregroundStyle(.black.opacity(0.7))

                            Text("等待局域网地址")
                                .font(.headline)
                                .foregroundStyle(.black.opacity(0.7))
                        }
                    }
            }
        }
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 14, y: 14)
        let scaledImage = outputImage.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
