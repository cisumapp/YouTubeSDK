//
//  YouTubeAISummary.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public struct YouTubeAISummary: Sendable {
    public let text: String
    public let highlights: [Highlight]
    
    public struct Highlight: Sendable {
        public let text: String
        public let startTimeSeconds: Int
        public let startIndex: Int
        public let length: Int
    }
    
    init?(from json: [String: Any]) {
        // Path: onResponseReceivedCommand.listMutationCommand.operations[0].insertItemSectionContent.contents[0].youChatItemViewModel
        guard let response = json["onResponseReceivedCommand"] as? [String: Any],
              let listMutation = response["listMutationCommand"] as? [String: Any],
              let operations = listMutation["operations"] as? [String: Any],
              let opsArray = operations["operations"] as? [[String: Any]],
              let firstOp = opsArray.first,
              let insert = firstOp["insertItemSectionContent"] as? [String: Any],
              let contents = insert["contents"] as? [[String: Any]],
              let viewModel = contents.first?["youChatItemViewModel"] as? [String: Any],
              let textDict = viewModel["text"] as? [String: Any],
              let content = textDict["content"] as? String else {
            return nil
        }
        
        self.text = content
        
        var highlights: [Highlight] = []
        if let runs = textDict["commandRuns"] as? [[String: Any]] {
            for run in runs {
                if let startIndex = run["startIndex"] as? Int,
                   let length = run["length"] as? Int,
                   let onTap = run["onTap"] as? [String: Any],
                   let innertubeCommand = onTap["innertubeCommand"] as? [String: Any],
                   let watchEndpoint = innertubeCommand["watchEndpoint"] as? [String: Any],
                   let startTime = watchEndpoint["startTimeSeconds"] as? Int {
                    
                    let rangeStart = content.index(content.startIndex, offsetBy: startIndex)
                    let rangeEnd = content.index(rangeStart, offsetBy: length)
                    let highlightText = String(content[rangeStart..<rangeEnd])
                    
                    highlights.append(Highlight(
                        text: highlightText,
                        startTimeSeconds: startTime,
                        startIndex: startIndex,
                        length: length
                    ))
                }
            }
        }
        self.highlights = highlights
    }
}
