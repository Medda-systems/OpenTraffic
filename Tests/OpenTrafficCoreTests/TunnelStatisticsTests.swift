import Foundation
import Testing
@testable import OpenTrafficCore

@Test func parsesCloudflaredMetricsIncludingScientificValuesAndOptionalTimestamps() {
    let text = """
    # HELP ignored ignored
    cloudflared_tunnel_total_requests 35 1789924999000
    cloudflared_tunnel_request_errors 0
    cloudflared_tunnel_response_by_code{status_code="200"} 31
    cloudflared_tunnel_response_by_code{status_code="404"} 1
    process_start_time_seconds 1.789924822e+09
    quic_client_sent_bytes{conn_index="0"} 2.5e+06
    quic_client_sent_bytes{conn_index="1"} 500000
    quic_client_receive_bytes{conn_index="0"} 1.25e+06
    quic_client_receive_bytes{conn_index="1"} 250000
    """
    let statistics = TunnelStatisticsParser.parse(text)
    #expect(statistics.totalRequests == 35)
    #expect(statistics.requestErrors == 0)
    #expect(statistics.responseByCode == ["200": 31, "404": 1])
    #expect(statistics.sentBytes == 3_000_000)
    #expect(statistics.receivedBytes == 1_500_000)
    #expect(statistics.transportBytes == 4_500_000)
    #expect(statistics.processStartedAt == Date(timeIntervalSince1970: 1_789_924_822))
}

@Test func rejectsNaNOverflowAndPartialTransportTotals() {
    let statistics = TunnelStatisticsParser.parse("""
    cloudflared_tunnel_total_requests NaN
    cloudflared_tunnel_request_errors +Inf
    quic_client_sent_bytes{conn_index="0"} 9.223372036854776e18
    """)
    #expect(statistics.totalRequests == nil)
    #expect(statistics.requestErrors == nil)
    #expect(statistics.sentBytes == nil)
    #expect(statistics.receivedBytes == nil)
    #expect(statistics.transportBytes == nil)

    let oneDirection = TunnelStatistics(sentBytes: 12, receivedBytes: nil)
    #expect(oneDirection.transportBytes == nil)
    let overflow = TunnelStatistics(sentBytes: .max, receivedBytes: 1)
    #expect(overflow.transportBytes == nil)
}
