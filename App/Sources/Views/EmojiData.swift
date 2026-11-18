import Foundation

struct EmojiItem: Identifiable, Hashable {
    let glyph: String
    let name: String
    let keywords: String
    let supportsTone: Bool

    var id: String { glyph }

    /// The glyph with the skin tone applied (1...5), or unchanged for tone 0 and for emoji without tones.
    func glyph(tone: Int) -> String {
        guard supportsTone, (1...5).contains(tone), let modifier = Unicode.Scalar(0x1F3FB + UInt32(tone - 1)) else {
            return glyph
        }
        let base = glyph.unicodeScalars.filter { $0.value != 0xFE0F }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: base)
        scalars.append(modifier)
        return String(scalars)
    }

    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query) || keywords.localizedCaseInsensitiveContains(query)
    }
}

struct EmojiCategory: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [EmojiItem]
}

/// A compact built-in set. Each line is `glyph|name|keywords`, with a trailing `|t` when skin tones apply.
enum EmojiData {
    static let defaultRecents = ["👍", "❤️", "😂", "🎉", "🚀", "👀", "🙏", "🔥", "✅", "😮", "😢", "👏", "💯", "🤔", "🙌", "👎"]

    static let categories: [EmojiCategory] = [
        make("smileys", "Smileys", "face.smiling", smileys),
        make("people", "People and gestures", "hand.wave", people),
        make("animals", "Animals and nature", "pawprint", animals),
        make("food", "Food and drink", "fork.knife", food),
        make("activities", "Activities", "soccerball", activities),
        make("travel", "Travel and places", "airplane", travel),
        make("objects", "Objects", "lightbulb", objects),
        make("symbols", "Symbols", "heart", symbols),
        make("flags", "Flags", "flag", flags),
    ]

    static let all: [EmojiItem] = categories.flatMap(\.items)

    static func item(for glyph: String) -> EmojiItem? {
        all.first { $0.glyph == glyph }
    }

    private static func make(_ id: String, _ title: String, _ symbol: String, _ lines: String) -> EmojiCategory {
        let items = lines.split(separator: "\n").compactMap { line -> EmojiItem? in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            return EmojiItem(
                glyph: parts[0], name: parts[1], keywords: parts.count > 2 ? parts[2] : "",
                supportsTone: parts.count > 3 && parts[3] == "t")
        }
        return EmojiCategory(id: id, title: title, symbol: symbol, items: items)
    }

    private static let smileys = """
        😀|grinning face|smile happy
        😃|grinning face with big eyes|smile happy
        😄|grinning face with smiling eyes|smile happy
        😁|beaming face|grin
        😆|grinning squinting face|laugh
        😅|grinning face with sweat|nervous relief
        🤣|rolling on the floor laughing|lol rofl
        😂|face with tears of joy|laugh lol cry
        🙂|slightly smiling face|smile
        🙃|upside-down face|silly
        😉|winking face|wink
        😊|smiling face with smiling eyes|blush happy
        😇|smiling face with halo|angel innocent
        🥰|smiling face with hearts|love adore
        😍|smiling face with heart-eyes|love crush
        🤩|star-struck|wow excited
        😘|face blowing a kiss|kiss love
        😗|kissing face|kiss
        😚|kissing face with closed eyes|kiss
        😋|face savoring food|yum delicious
        😛|face with tongue|playful
        😜|winking face with tongue|joke crazy
        🤪|zany face|crazy wild
        😝|squinting face with tongue|silly
        🤑|money-mouth face|rich dollar
        🤗|smiling face with open hands|hug
        🤭|face with hand over mouth|oops giggle
        🤫|shushing face|quiet secret
        🤔|thinking face|hmm consider
        🤐|zipper-mouth face|secret silent
        🤨|face with raised eyebrow|skeptical
        😐|neutral face|meh
        😑|expressionless face|blank
        😶|face without mouth|speechless
        😏|smirking face|smug
        😒|unamused face|unimpressed
        🙄|face with rolling eyes|eyeroll annoyed
        😬|grimacing face|awkward
        🤥|lying face|pinocchio
        😌|relieved face|calm
        😔|pensive face|sad thoughtful
        😪|sleepy face|tired
        🤤|drooling face|want
        😴|sleeping face|zzz tired
        😷|face with medical mask|sick
        🤒|face with thermometer|ill fever
        🤕|face with head-bandage|hurt injured
        🤢|nauseated face|sick gross
        🤮|face vomiting|sick
        🤧|sneezing face|cold
        🥵|hot face|heat
        🥶|cold face|freezing
        🥴|woozy face|dizzy drunk
        😵|face with crossed-out eyes|dizzy
        🤯|exploding head|mind blown
        🤠|cowboy hat face|yeehaw
        🥳|partying face|party celebrate
        😎|smiling face with sunglasses|cool
        🤓|nerd face|geek
        🧐|face with monocle|inspect
        😕|confused face|puzzled
        😟|worried face|anxious
        🙁|slightly frowning face|sad
        😮|face with open mouth|surprised wow
        😯|hushed face|surprised
        😲|astonished face|shocked
        😳|flushed face|embarrassed
        🥺|pleading face|puppy eyes please
        😦|frowning face with open mouth|shocked
        😨|fearful face|scared
        😰|anxious face with sweat|worried
        😥|sad but relieved face|phew
        😢|crying face|sad tear
        😭|loudly crying face|sob
        😱|face screaming in fear|scream shocked
        😖|confounded face|upset
        😣|persevering face|struggle
        😞|disappointed face|sad
        😓|downcast face with sweat|stress
        😩|weary face|tired
        😫|tired face|exhausted
        🥱|yawning face|bored sleepy
        😤|face with steam from nose|frustrated
        😡|enraged face|angry mad
        😠|angry face|mad
        🤬|face with symbols on mouth|swearing
        😈|smiling face with horns|devil
        💀|skull|dead
        💩|pile of poo|poop
        🤡|clown face|clown
        👻|ghost|boo halloween
        👽|alien|ufo
        🤖|robot|bot
        """

    private static let people = """
        👍|thumbs up|like yes approve ok|t
        👎|thumbs down|dislike no|t
        👌|ok hand|perfect|t
        ✌️|victory hand|peace|t
        🤞|crossed fingers|luck hope|t
        🤟|love-you gesture|rock|t
        🤘|sign of the horns|rock metal|t
        🤙|call me hand|phone|t
        👈|backhand index pointing left|point|t
        👉|backhand index pointing right|point|t
        👆|backhand index pointing up|point|t
        👇|backhand index pointing down|point|t
        ☝️|index pointing up|one|t
        ✋|raised hand|stop high five|t
        🤚|raised back of hand|stop|t
        🖐️|hand with fingers splayed|five|t
        🖖|vulcan salute|spock|t
        👋|waving hand|hello bye|t
        🙏|folded hands|thanks please pray|t
        💪|flexed biceps|strong muscle|t
        👏|clapping hands|applause bravo|t
        🙌|raising hands|celebrate hooray|t
        👐|open hands|jazz|t
        🤲|palms up together|offer|t
        🤝|handshake|deal agree
        ✍️|writing hand|write|t
        🤳|selfie|photo|t
        💅|nail polish|beauty|t
        🙋|person raising hand|question volunteer|t
        🙆|person gesturing ok|ok|t
        🙅|person gesturing no|no|t
        🤷|person shrugging|dunno idk|t
        🤦|person facepalming|facepalm|t
        🙇|person bowing|sorry respect|t
        💁|person tipping hand|sassy|t
        👶|baby|child|t
        🧑|person|adult|t
        👩|woman|female|t
        👨|man|male|t
        🧓|older person|elder|t
        👀|eyes|look watching
        🧠|brain|smart think
        🫡|saluting face|respect salute
        """

    private static let animals = """
        🐶|dog face|puppy pet
        🐱|cat face|kitten pet
        🐭|mouse face|rodent
        🐹|hamster|pet
        🐰|rabbit face|bunny
        🦊|fox|clever
        🐻|bear|teddy
        🐼|panda|bear
        🐨|koala|australia
        🐯|tiger face|cat
        🦁|lion|king
        🐮|cow face|moo
        🐷|pig face|oink
        🐸|frog|toad
        🐵|monkey face|ape
        🙈|see-no-evil monkey|shy
        🙉|hear-no-evil monkey|deaf
        🙊|speak-no-evil monkey|secret
        🐔|chicken|hen
        🐧|penguin|linux
        🐦|bird|tweet
        🦆|duck|quack
        🦉|owl|wise
        🐺|wolf|howl
        🐴|horse face|pony
        🦄|unicorn|magic
        🐝|honeybee|bee
        🦋|butterfly|insect
        🐛|bug|caterpillar insect
        🐌|snail|slow
        🐞|lady beetle|ladybug
        🐢|turtle|slow
        🐍|snake|python
        🐙|octopus|sea
        🦀|crab|rust
        🐠|tropical fish|sea
        🐬|dolphin|sea
        🐳|spouting whale|sea
        🦈|shark|sea
        🐘|elephant|big
        🦒|giraffe|tall
        🌵|cactus|desert
        🌲|evergreen tree|pine
        🌴|palm tree|tropical
        🍀|four leaf clover|luck
        🌸|cherry blossom|flower spring
        🌹|rose|flower love
        🌻|sunflower|flower
        🌈|rainbow|pride weather
        ☀️|sun|sunny weather
        🌙|crescent moon|night
        ⭐|star|favorite
        ☁️|cloud|weather
        ❄️|snowflake|winter cold
        🌊|water wave|sea
        """

    private static let food = """
        🍎|red apple|fruit
        🍐|pear|fruit
        🍊|tangerine|orange fruit
        🍋|lemon|fruit sour
        🍌|banana|fruit
        🍉|watermelon|fruit
        🍇|grapes|fruit
        🍓|strawberry|fruit berry
        🍒|cherries|fruit
        🍑|peach|fruit
        🍍|pineapple|fruit
        🥑|avocado|fruit
        🍅|tomato|vegetable
        🥕|carrot|vegetable
        🌽|ear of corn|vegetable
        🍞|bread|toast
        🧀|cheese wedge|dairy
        🥚|egg|breakfast
        🥓|bacon|breakfast
        🍔|hamburger|burger
        🍟|french fries|chips
        🍕|pizza|slice
        🌭|hot dog|sausage
        🥪|sandwich|lunch
        🌮|taco|mexican
        🍝|spaghetti|pasta
        🍜|steaming bowl|ramen noodles
        🍣|sushi|japanese
        🍦|soft ice cream|dessert
        🍩|doughnut|donut dessert
        🍪|cookie|biscuit dessert
        🎂|birthday cake|party
        🍰|shortcake|dessert
        🍫|chocolate bar|sweet
        🍿|popcorn|movie
        ☕|hot beverage|coffee tea
        🍵|teacup without handle|tea
        🍺|beer mug|drink
        🍻|clinking beer mugs|cheers
        🥂|clinking glasses|cheers toast
        🍷|wine glass|drink
        🍸|cocktail glass|drink
        🥤|cup with straw|soda
        """

    private static let activities = """
        ⚽|soccer ball|football
        🏀|basketball|sport
        🏈|american football|sport
        ⚾|baseball|sport
        🎾|tennis|sport
        🏐|volleyball|sport
        🏓|ping pong|table tennis
        🥊|boxing glove|fight
        🎯|bullseye|target goal
        ⛳|flag in hole|golf
        🎣|fishing pole|fish
        🎮|video game|controller gaming
        🎲|game die|dice luck
        🧩|puzzle piece|jigsaw
        🎭|performing arts|theater
        🎨|artist palette|art paint
        🎬|clapper board|movie film
        🎤|microphone|sing karaoke
        🎧|headphone|music
        🎸|guitar|music rock
        🎹|musical keyboard|piano
        🥁|drum|music
        🎺|trumpet|music
        🎻|violin|music
        🏆|trophy|win champion
        🥇|first place medal|gold winner
        🥈|second place medal|silver
        🥉|third place medal|bronze
        🏅|sports medal|award
        🎉|party popper|celebrate congratulations tada
        🎊|confetti ball|celebrate
        🎈|balloon|party
        🎁|wrapped gift|present
        """

    private static let travel = """
        🚗|automobile|car
        🚕|taxi|cab
        🚌|bus|transport
        🚓|police car|cop
        🚑|ambulance|emergency
        🚒|fire engine|truck
        🚚|delivery truck|shipping
        🚲|bicycle|bike
        🏍️|motorcycle|bike
        ✈️|airplane|flight travel
        🚀|rocket|launch ship fast
        🛸|flying saucer|ufo
        🚁|helicopter|fly
        ⛵|sailboat|boat
        🚢|ship|cruise
        🚂|locomotive|train
        🚆|train|rail
        🗺️|world map|travel
        🏠|house|home
        🏢|office building|work
        🏥|hospital|health
        🏫|school|education
        ⛪|church|religion
        🗽|statue of liberty|new york
        🗼|tokyo tower|japan
        🌋|volcano|eruption
        🏖️|beach with umbrella|holiday
        ⛺|tent|camping
        🌅|sunrise|morning
        🌃|night with stars|city
        """

    private static let objects = """
        ⌚|watch|time
        📱|mobile phone|iphone
        💻|laptop|computer mac
        ⌨️|keyboard|type
        🖥️|desktop computer|screen
        🖱️|computer mouse|click
        💾|floppy disk|save
        📷|camera|photo
        📺|television|tv
        ⏰|alarm clock|time wake
        💡|light bulb|idea
        🔦|flashlight|torch
        🔋|battery|power
        🔌|electric plug|power
        💰|money bag|cash
        💳|credit card|payment
        💎|gem stone|diamond
        🔧|wrench|tool fix
        🔨|hammer|tool build
        ⚙️|gear|settings
        🔒|locked|security
        🔓|unlocked|open
        🔑|key|password
        📌|pushpin|pin
        📎|paperclip|attach
        ✂️|scissors|cut
        📝|memo|note write
        📚|books|read library
        📖|open book|read
        📅|calendar|date
        📊|bar chart|stats data
        📈|chart increasing|growth up
        📉|chart decreasing|down
        📦|package|box shipping
        📧|e-mail|mail
        ✉️|envelope|mail letter
        📞|telephone receiver|call
        🔔|bell|notification
        🔕|bell with slash|mute silent
        🎵|musical note|music
        🛠️|hammer and wrench|tools
        🧰|toolbox|tools
        🧪|test tube|experiment
        🔬|microscope|science
        💊|pill|medicine
        """

    private static let symbols = """
        ❤️|red heart|love
        🧡|orange heart|love
        💛|yellow heart|love
        💚|green heart|love
        💙|blue heart|love
        💜|purple heart|love
        🖤|black heart|love
        🤍|white heart|love
        💔|broken heart|sad
        💕|two hearts|love
        💖|sparkling heart|love
        💯|hundred points|perfect
        ✅|check mark button|done yes
        ❌|cross mark|no wrong
        ❎|cross mark button|no
        ✔️|check mark|done
        ➕|plus|add
        ➖|minus|remove
        ❓|red question mark|question
        ❗|red exclamation mark|important
        ‼️|double exclamation mark|important
        ⚠️|warning|caution
        🚫|prohibited|no ban
        ⛔|no entry|stop
        ♻️|recycling symbol|recycle
        🔴|red circle|dot
        🟠|orange circle|dot
        🟡|yellow circle|dot
        🟢|green circle|dot ok
        🔵|blue circle|dot
        🟣|purple circle|dot
        ➡️|right arrow|next
        ⬅️|left arrow|back
        ⬆️|up arrow|up
        ⬇️|down arrow|down
        🔄|counterclockwise arrows|refresh sync
        🔥|fire|hot lit
        ⚡|high voltage|lightning fast
        ✨|sparkles|magic new
        🌟|glowing star|star
        💥|collision|boom
        💫|dizzy|star
        💢|anger symbol|mad
        💤|zzz|sleep
        🆗|ok button|ok
        🆕|new button|new
        🆒|cool button|cool
        🔝|top arrow|top
        ℹ️|information|info
        """

    private static let flags = """
        🇧🇬|flag Bulgaria|bulgaria bg
        🇩🇪|flag Germany|germany de
        🇺🇸|flag United States|usa america
        🇬🇧|flag United Kingdom|uk britain
        🇫🇷|flag France|france
        🇮🇹|flag Italy|italy
        🇪🇸|flag Spain|spain
        🇳🇱|flag Netherlands|holland
        🇵🇱|flag Poland|poland
        🇷🇴|flag Romania|romania
        🇬🇷|flag Greece|greece
        🇹🇷|flag Turkey|turkey
        🇺🇦|flag Ukraine|ukraine
        🇨🇦|flag Canada|canada
        🇯🇵|flag Japan|japan
        🇨🇳|flag China|china
        🇰🇷|flag South Korea|korea
        🇮🇳|flag India|india
        🇧🇷|flag Brazil|brazil
        🇦🇺|flag Australia|australia
        🇨🇭|flag Switzerland|swiss
        🇸🇪|flag Sweden|sweden
        🇳🇴|flag Norway|norway
        🇮🇪|flag Ireland|ireland
        🇪🇺|flag European Union|eu europe
        🏳️|white flag|surrender
        🏴|black flag|pirate
        🏁|chequered flag|finish race
        🚩|triangular flag|red flag
        🏳️‍🌈|rainbow flag|pride lgbt
        """
}
