import Foundation
import DNS
import Socket
#if os(Linux)
    import Dispatch
#endif


class Client: UDPChannelDelegate {
    enum Error: Swift.Error {
        case channelSetupError(Swift.Error)
    }
    
    let ipv4Group: Socket.Address = {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = IPv4("224.0.0.251")!.address
        addr.sin_port = (5353 as in_port_t).bigEndian
        return .ipv4(addr)
    }()
    
    let ipv6Group: Socket.Address = {
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET)
        addr.sin6_addr = IPv6("FF02::FB")!.address
        addr.sin6_port = (5353 as in_port_t).bigEndian
        return .ipv6(addr)
    }()
    
    private static var _shared: Client?
    internal static func shared() throws -> Client {
        if let shared = _shared {
            return shared
        }
        _shared = try Client()
        return _shared!
    }

    internal var listeners = [Listener]()
    internal var responders = [Responder]()
    let queue = DispatchQueue.global(qos: .userInteractive)
    let channels: [UDPChannel]

    private init() throws {
        do {
            try channels = [
                UDPChannel(group: ipv4Group, queue: queue),
                UDPChannel(group: ipv6Group, queue: queue)
            ]
        } catch {
            throw Error.channelSetupError(error)
        }
        channels.forEach { $0.delegate = self }
    }
    
    func channel(_ channel: UDPChannel, didReceive data: Data, from source: Socket.Address) {
        let message = Message(unpack: data)
       
        if message.header.response {
            for listener in self.listeners {
                listener.received(message: message)
            }
            return
        } else {
            var answers = [ResourceRecord]()
            var authorities = [ResourceRecord]()
            var additional = [ResourceRecord]()
            
            for responder in self.responders {
                guard let response = responder.respond(toMessage: message) else {
                    continue
                }
                answers += response.answers
                authorities += response.authorities
                additional += response.additional
            }
            
            guard answers.count > 0 else {
                return
            }
            
            var response = Message(header: Header(response: true), answers: answers, authorities: authorities, additional: additional)
            
            // The destination UDP port in all Multicast DNS responses MUST be 5353,
            // and the destination address MUST be the mDNS IPv4 link-local
            // multicast address 224.0.0.251 or its IPv6 equivalent FF02::FB, except
            // when generating a reply to a query that explicitly requested a
            // unicast response:
            //
            //    * via the unicast-response bit,
            //    * by virtue of being a legacy query (Section 6.7), or
            //    * by virtue of being a direct unicast query.
            //
            /// @todo: implement this logic
            if source.port == 5353 {
                try! channel.multicast(Data(bytes: response.pack()))
            } else {
                // In this case, the Multicast DNS responder MUST send a UDP response
                // directly back to the querier, via unicast, to the query packet's
                // source IP address and port.  This unicast response MUST be a
                // conventional unicast response as would be generated by a conventional
                // Unicast DNS server; for example, it MUST repeat the query ID and the
                // question given in the query message.  In addition, the cache-flush
                // bit described in Section 10.2, "Announcements to Flush Outdated Cache
                // Entries", MUST NOT be set in legacy unicast responses.
                response.header.id = message.header.id
                
                try! channel.unicast(Data(bytes: response.pack()), to: source)
            }
        }
    }
    
    func multicast(message: Message) throws {
        for channel in channels {
            try channel.multicast(Data(bytes: message.pack()))
        }
    }
}

protocol Listener: class {
    func received(message: Message)
}

protocol Responder: class {
    func respond(toMessage: Message) -> (answers: [ResourceRecord], authorities: [ResourceRecord], additional: [ResourceRecord])?
}
