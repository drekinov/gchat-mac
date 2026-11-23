import Foundation

enum FakeScript {
    enum Feature {
        case mention, longMessage, link, uploaded, drive, deleted
    }

    struct NamedSpace {
        let title: String
        let threaded: Bool
        let messages: Int
        let unread: Int
        var muted = false
        var historyOff = false
        /// Replies at the end of one thread that stay unread, with the rest of that thread read.
        var unreadReplies = 0
    }

    struct Direct {
        enum Kind: Equatable {
            case person(Int)
            case bot
            case group([Int])
        }

        let kind: Kind
        let messages: Int
        let unread: Int
    }

    struct Org {
        let name: String
        let people: [String]
        let bot: String
        let spaces: [NamedSpace]
        let directs: [Direct]
    }

    static let maxAccounts = 6

    static let handwritten: [Org] = [
        Org(
            name: "Studio A",
            people: ["Morgan Reed", "Robin Lane", "Avery Quinn", "Riley Brooks", "Taylor Rowan"],
            bot: "Standup Bot",
            spaces: [
                NamedSpace(title: "Engineering", threaded: true, messages: 40, unread: 4),
                NamedSpace(title: "Releases", threaded: true, messages: 22, unread: 0, unreadReplies: 2),
                NamedSpace(title: "Design Reviews", threaded: false, messages: 17, unread: 3),
                NamedSpace(title: "Random", threaded: false, messages: 31, unread: 9, muted: true),
                NamedSpace(title: "On-call Handover", threaded: false, messages: 8, unread: 0, historyOff: true),
                NamedSpace(title: "Studio Lounge", threaded: false, messages: 4, unread: 1),
            ],
            directs: [
                Direct(kind: .person(0), messages: 14, unread: 2),
                Direct(kind: .bot, messages: 5, unread: 1),
                Direct(kind: .person(3), messages: 9, unread: 0),
                Direct(kind: .group([1, 2, 4]), messages: 19, unread: 5),
            ]),
        Org(
            name: "Org B",
            people: ["Alex Chen", "Priya Natarajan", "Sam Okafor", "Lena Fischer"],
            bot: "Jira Cloud",
            spaces: [
                NamedSpace(title: "Product Launch", threaded: true, messages: 36, unread: 6),
                NamedSpace(title: "Customer Success", threaded: false, messages: 25, unread: 0),
                NamedSpace(title: "Finance", threaded: false, messages: 11, unread: 2),
                NamedSpace(title: "Announcements", threaded: false, messages: 6, unread: 0, muted: true),
                NamedSpace(title: "Hiring", threaded: false, messages: 3, unread: 1),
            ],
            directs: [
                Direct(kind: .person(1), messages: 12, unread: 3),
                Direct(kind: .bot, messages: 7, unread: 0),
                Direct(kind: .group([0, 2, 3]), messages: 16, unread: 0),
            ]),
        Org(
            name: "Org C",
            people: ["Tomas Novak", "Ana Silva", "Kenji Sato", "Hannah Weiss", "Omar Haddad", "Chloe Martin"],
            bot: "GitHub",
            spaces: [
                NamedSpace(title: "Platform Team", threaded: true, messages: 33, unread: 0),
                NamedSpace(title: "Incidents", threaded: false, messages: 15, unread: 7, muted: true),
                NamedSpace(title: "Data & Analytics", threaded: false, messages: 9, unread: 2),
                NamedSpace(title: "Social", threaded: false, messages: 5, unread: 0),
            ],
            directs: [
                Direct(kind: .person(2), messages: 10, unread: 1),
                Direct(kind: .bot, messages: 4, unread: 0),
                Direct(kind: .group([0, 1, 5]), messages: 13, unread: 4),
            ]),
    ]

    static func org(_ index: Int) -> Org {
        index < handwritten.count ? handwritten[index] : generated(index)
    }

    private static let generatedNames = ["Northwind", "Harborline", "Lumen Labs"]
    private static let generatedBots = ["Calendar", "Linear", "PagerDuty"]
    private static let generatedSpaces: [[String]] = [
        ["Operations", "Sales EMEA", "Warehouse", "Quality", "Procurement", "Lunch Club"],
        ["Deal Desk", "Marketing", "Partnerships", "Legal Review", "Events", "Kudos"],
        ["Research", "ML Platform", "Lab Notes", "Paper Club", "Hardware", "Random"],
    ]
    private static let peoplePool = [
        "Devon Finch", "Wren Ellis", "Luca Bianchi", "Mei Lin", "Carlos Mendez", "Ingrid Larsen", "Yusuf Demir",
        "Nadia Kowalski", "Ben Carter", "Olivia Brown", "Dmitri Volkov", "Fatima Zahra", "Jonas Weber", "Aisha Khan",
        "Pierre Dubois", "Zoe Papadopoulos", "Hugo Silva", "Lucy Evans", "Marek Nowak", "Sara Lindqvist",
    ]

    /// Deterministic: the same index always yields the same org.
    private static func generated(_ index: Int) -> Org {
        let slot = (index - handwritten.count) % generatedNames.count
        let people = (0..<(4 + slot)).map { peoplePool[(index * 5 + $0 * 3) % peoplePool.count] }
        let titles = generatedSpaces[slot]
        let counts = [30, 18, 9, 26, 5, 12]
        let unread = [3, 0, 2, 5, 0, 1]
        let spaces = titles.prefix(4 + slot).enumerated().map { offset, title in
            NamedSpace(
                title: title, threaded: offset == 0, messages: counts[offset], unread: unread[offset],
                muted: offset == 3)
        }
        return Org(
            name: generatedNames[slot], people: people, bot: generatedBots[slot], spaces: Array(spaces),
            directs: [
                Direct(kind: .person(0), messages: 11, unread: 1), Direct(kind: .bot, messages: 5, unread: 0),
                Direct(kind: .group([1, 2, 3]), messages: 14, unread: 2),
            ])
    }

    private static let directoryPool = [
        "Alice Morgan", "Bruno Costa", "Chiara Rossi", "Dario Ferrari", "Elif Yilmaz", "Felix Hartmann", "Greta Olsen",
        "Hassan Ali", "Irene Petrov", "Jakub Kowalczyk", "Katya Smirnova", "Leo Fontaine", "Mina Park", "Nils Berg",
        "Oscar Lund", "Petra Novakova", "Quentin Roy", "Rosa Delgado", "Stefan Vogel", "Tara Quinn", "Umar Farooq",
        "Vera Lindgren", "Willem de Vries", "Xenia Ivanova", "Yara Haddad", "Zoltan Kiss", "Ada Okoro", "Boris Pavlov",
        "Carla Mendes", "Rowan Ash", "Emma Walsh", "Filip Horvat", "Gaia Conti", "Henrik Dahl", "Ines Duarte",
        "Jonas Keller", "Klara Svoboda", "Luka Babic", "Mara Popescu", "Nora Eriksen",
    ]

    /// People in the Workspace directory the account has no chat with.
    static func directoryNames(org index: Int) -> [String] {
        (0..<10).map { directoryPool[(index * 10 + $0) % directoryPool.count] }
    }

    static func emailDomain(_ org: Org) -> String {
        org.name.lowercased().filter { $0.isLetter || $0.isNumber } + ".example"
    }

    static func email(_ name: String, org: Org) -> String {
        name.lowercased().split(separator: " ").joined(separator: ".") + "@" + emailDomain(org)
    }

    static let reactors = [
        "Anna Lee", "Mark Spencer", "Priya Rao", "Tom Jensen", "Lea Moreau", "Sven Berg", "Amira Said", "Kofi Mensah",
        "Rita Costa", "Paul Wagner", "Yuki Tanaka", "Dana Cohen", "Eli Brooks", "Noor Aziz",
    ]

    static let reactionEmoji = ["👍", "❤️", "😂", "🎉", "🚀", "👀", "🙏", "🔥", "✅", "😮"]

    static let attachmentPool: [(name: String, type: String)] = [
        ("screenshot-2026-10-13.png", "image/png"), ("site-photo.jpg", "image/jpeg"), ("reaction.gif", "image/gif"),
        ("IMG_4021.heic", "image/heic"), ("Meeting-notes.pdf", "application/pdf"),
        ("assets-export.zip", "application/zip"), ("Proposal-v2.docx", Mime.docx), ("Forecast.xlsx", Mime.xlsx),
        ("walkthrough.mp4", "video/mp4"), ("standup-recording.mov", "video/quicktime"),
    ]

    enum Mime {
        static let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        static let xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        static let pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        static let gdoc = "application/vnd.google-apps.document"
        static let gsheet = "application/vnd.google-apps.spreadsheet"
        static let gslides = "application/vnd.google-apps.presentation"
    }

    static let emojiLines: [String] = [
        "Shipped it! 🚀🎉", "Family dinner tonight 👨‍👩‍👧‍👦", "Thanks 👍🏽", "Greetings from 🇧🇬 and 🇩🇪",
        "Pride month banner is live 🏳️‍🌈", "New teammate 👩🏽‍💻 joins on Monday", "Coffee? ☕️", "That demo was 🔥🔥🔥",
    ]

    static let chatter: [String] = [
        "Morning all, quick heads up that the deploy window moves to 15:00 today.",
        "Can someone review my PR when they get a chance? It's a small one.",
        "Looks good to me, merging after CI is green.",
        "I'm seeing the same timeout on staging, restarting the worker now.",
        "Thanks, that fixed it.",
        "Lunch at 13:00? The new place on the corner has a decent menu.",
        "Reminder: the retro is tomorrow at 10:30, please add your points to the doc.",
        "Do we have numbers for last week's conversion yet?",
        "I'll take that one, give me until end of day.",
        "The client came back with a few more changes, nothing blocking.",
        "Heads up, I'm out Thursday and Friday.",
        "Great work on the launch, everyone!",
        "Can we move this to a call? Easier to walk through it live.",
        "Pushed a fix, please pull before you start on the next ticket.",
        "Anyone else getting logged out of the admin panel every few minutes?",
        "+1 from me.",
        "Sounds good, let's do it.",
        "I'll update the ticket and ping you once it's deployed.",
        "Is the staging database in sync with production again?",
        "Invoice sent, waiting on their approval.",
        "Not yet, still waiting on legal.",
        "That works for me.",
        "Can you share the link?",
        "Done, thanks!",
        "Let me check and get back to you.",
        "We should probably write this up so it doesn't happen again.",
        "The new build is 40% faster on my machine, will post the profile later.",
        "Coffee machine on the 2nd floor is broken again, use the one downstairs.",
    ]

    static let botLines: [String] = [
        "Reminder: standup starts in 10 minutes.",
        "Build #482 passed on main.",
        "Build #483 failed: 2 tests failing in checkout-service.",
        "You were assigned PLAT-2291: Investigate slow report export.",
        "Weekly summary: 14 tickets closed, 6 opened.",
        "Deployment to staging finished successfully.",
    ]

    static let longMessage = """
        Quick write-up of where we landed after Tuesday's planning session, so everyone has it in one place.

        First, the rollout. We will ship to internal users on Monday, then to 10% of customers on Wednesday if the \
        error budget holds. The feature flag is already in place and the dashboards are linked from the runbook. \
        If anything looks off, the on-call engineer can flip the flag without a deploy.

        Second, migrations. The schema change is additive and backwards compatible, so we can run it ahead of the code \
        release. I'd like to do it on Friday afternoon when traffic is low, with Robin watching the replication lag. \
        We have a rollback script, but it has only been tested on a copy of staging.

        Third, open questions: who owns the customer announcement, and do we want to hold back the reporting changes \
        until the following sprint? Please reply in this thread rather than in DMs so the context stays together.
        """
}
