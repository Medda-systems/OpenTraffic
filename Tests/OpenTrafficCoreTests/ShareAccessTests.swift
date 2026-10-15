import Foundation
import Testing
@testable import OpenTrafficCore

@Test func accessCookiesAndInvitesBelongToOneShareAndOnePassword() {
    let access = ShareAccess(password: "p4ss", shareKey: "a", shareName: "A")
    let otherShare = ShareAccess(password: "p4ss", shareKey: "b", shareName: "B")
    let newPassword = ShareAccess(password: "other", shareKey: "a", shareName: "A")
    #expect(access.cookieValue != otherShare.cookieValue)
    #expect(access.cookieValue != newPassword.cookieValue)
    #expect(access.inviteToken != access.cookieValue)
    #expect(!access.cookieValue.contains("p4ss"))
    #expect(!access.cookieValue.contains(where: { "+/=".contains($0) }))
    #expect(access.accepts(cookie: access.cookieValue))
    #expect(!access.accepts(cookie: otherShare.cookieValue))
    #expect(!access.accepts(cookie: ""))
    #expect(access.accepts(invite: access.inviteToken))
    #expect(!access.accepts(invite: access.cookieValue))
}

@Test func basicAuthTakesAnyUsername() {
    let access = ShareAccess(password: "p:4ss", shareKey: "a", shareName: "A")
    #expect(access.accepts(authorization: "Basic " + Data("x:p:4ss".utf8).base64EncodedString()))
    #expect(access.accepts(authorization: "basic " + Data(":p:4ss".utf8).base64EncodedString()))
    #expect(!access.accepts(authorization: "Basic " + Data("p:4ss".utf8).base64EncodedString()))
    #expect(!access.accepts(authorization: "Bearer p:4ss"))
    #expect(!access.accepts(authorization: "Basic !!!"))
}

@Test func signInOnlyContinuesWithinTheShare() {
    #expect(ShareAccess.safeNext("/cart?id=2") == "/cart?id=2")
    #expect(ShareAccess.safeNext(nil) == "/")
    #expect(ShareAccess.safeNext("https://evil.example/") == "/")
    #expect(ShareAccess.safeNext("//evil.example/") == "/")
    #expect(ShareAccess.safeNext("/\\evil.example") == "/")
    #expect(ShareAccess.safeNext("/a\r\nSet-Cookie: x") == "/")
    #expect(ShareAccess.safeNext(ShareAccess.signInPath) == "/")
    #expect(ShareAccess.removingInvite(from: "/a?ot_invite=t&b=1") == "/a?b=1")
    #expect(ShareAccess.removingInvite(from: "/a?ot_invite=t") == "/a")
}

@Test func inviteLinksKeepTheRestOfTheLink() {
    let access = ShareAccess(password: "p4ss", shareKey: "a", shareName: "A")
    #expect(access.inviteURL(publicURL: "https://x.trycloudflare.com") == "https://x.trycloudflare.com/?ot_invite=\(access.inviteToken)")
    #expect(access.inviteURL(publicURL: "https://x.example/p?q=1&ot_invite=old") == "https://x.example/p?q=1&ot_invite=\(access.inviteToken)")
}

@Test func signInPagesEscapeWhatTheyShow() {
    let page = ShareAccess.signInPage(shareName: #"<img src=x onerror=alert(1)>"#, next: #"/"><script>"#, error: "<b>")
    #expect(!page.contains("<img"))
    #expect(!page.contains(#""><script>"#))
    #expect(page.contains("&lt;b&gt;"))
    let done = ShareAccess.signedInPage(next: "/</script><script>alert(1)//", name: "Ada</script>")
    #expect(!done.contains("</script><script>alert"))
    #expect(ShareAccess.formFields(Data("password=a%26b+c&next=%2Fx&password=second".utf8)) == ["password": "a&b c", "next": "/x"])
}

@Test func signInLimiterForgetsOldTries() {
    var limiter = SignInLimiter()
    let start = Date()
    for second in 0..<SignInLimiter.maximumFailures { limiter.failed("ip", at: start.addingTimeInterval(Double(second))) }
    #expect(!limiter.allows("ip", now: start.addingTimeInterval(10)))
    #expect(limiter.allows("other", now: start.addingTimeInterval(10)))
    #expect(limiter.allows("ip", now: start.addingTimeInterval(SignInLimiter.window + 5)))
}

@Test func theNameFieldIsOnlyThereForCollaboration() {
    #expect(ShareAccess.signInPage(shareName: "S", next: "/", asksName: true).contains(#"name="name""#))
    #expect(!ShareAccess.signInPage(shareName: "S", next: "/").contains(#"name="name""#))
}

@Test func theSignInPageIsFilledInCompletely() {
    let page = ShareAccess.signInPage(shareName: "Orbit", next: "/cart", error: "Wrong", asksName: true)
    #expect(!page.contains("__OT_"))
    #expect(!page.contains("data-ot-slot"))
    #expect(page.contains("<title>Orbit · OpenTraffic</title>"))
    #expect(page.contains(#"aria-invalid="true""#) && page.contains(">Wrong</div>"))
    #expect(!ShareAccess.signInPage(shareName: "S", next: "/").contains(#"aria-invalid="true""#))
}
