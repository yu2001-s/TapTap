import Foundation

/// CSV format written by `taptap collect`: t,ax,ay,az,gx,gy,gz[,key_age,click_age]
public enum Recording {
    public static let header = "t,ax,ay,az,gx,gy,gz,key_age,click_age"

    public static func load(_ path: String) throws -> [IMUSample] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var out: [IMUSample] = []
        for line in text.split(separator: "\n").dropFirst() {
            let v = line.split(separator: ",").compactMap { Double($0) }
            guard v.count >= 7 else { continue }
            out.append(IMUSample(t: v[0], a: SIMD3(v[1], v[2], v[3]), g: SIMD3(v[4], v[5], v[6]),
                                 keyAge: v.count > 7 ? v[7] : 99, clickAge: v.count > 8 ? v[8] : 99))
        }
        return out
    }

    public static func row(_ s: IMUSample) -> String {
        String(format: "%.5f,%.6f,%.6f,%.6f,%.5f,%.5f,%.5f,%.3f,%.3f\n",
               s.t, s.a.x, s.a.y, s.a.z, s.g.x, s.g.y, s.g.z, min(s.keyAge, 99), min(s.clickAge, 99))
    }
}
