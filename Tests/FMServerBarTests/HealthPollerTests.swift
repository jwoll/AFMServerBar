import Testing
import Foundation
@testable import FMServerBar

@Test func decodesHealthJSON() throws {
    let json = """
    {"status":"fm serve is running","models":[
      {"name":"system","available":true},
      {"name":"pcc","available":false,"reason":"Private Cloud Compute is not available in this context."}]}
    """.data(using: .utf8)!
    let health = try JSONDecoder().decode(Health.self, from: json)
    #expect(health.status == "fm serve is running")
    #expect(health.models.count == 2)
    #expect(health.model(named: "system")?.available == true)
    #expect(health.model(named: "pcc")?.available == false)
    #expect(health.model(named: "pcc")?.reason?.contains("not available") == true)
    #expect(health.systemAvailable == true)
}
