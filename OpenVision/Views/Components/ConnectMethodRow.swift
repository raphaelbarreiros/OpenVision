// OpenVision - ConnectMethodRow.swift
// One option in a backend's "Connect With" list (API key vs. subscription sign-in).
//
// A choice of how to connect, not a view switch — so the settings screens use an inline,
// checkmark Picker of these rows (as in iOS Settings) rather than a segmented control, with each
// option's trade-off in its subtitle so it's read before choosing.

import SwiftUI

struct ConnectMethodRow: View {
    let title: String
    let summary: String
    let icon: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}
