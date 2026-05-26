import Foundation

// MARK: - Feed feedback notification names
//
// Posted by InternalVideoCardView when the user selects a feed feedback action
// (Not Interested, Don't Like, Don't Recommend Channel).
// Defined here in SmartTubeIOSCore so ViewModels can observe without
// importing the SmartTubeIOS UI module.

public extension Notification.Name {
    /// Posted when a specific video should be removed from the current feed.
    /// userInfo key: "videoId" (String)
    static let hideInternalVideoFromFeed   = Notification.Name("com.smarttube.hideInternalVideoFromFeed")
    /// Posted when all videos from a channel should be removed from the current feed.
    /// userInfo key: "channelId" (String)
    static let hideChannelFromFeed = Notification.Name("com.smarttube.hideChannelFromFeed")
}
