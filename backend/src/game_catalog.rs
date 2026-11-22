use serde::Serialize;

pub const GAME_CATEGORIES: [&str; 6] = [
    "เพื่อน",
    "ครอบครัว",
    "ทำงาน",
    "ความรู้",
    "ทายใจ/ฮา",
    "สร้างสรรค์",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct GameCatalogItem {
    pub number: u16,
    pub id: &'static str,
    pub name: &'static str,
    pub tagline: &'static str,
    pub emoji: &'static str,
    pub category: &'static str,
    pub play_mode: &'static str,
    pub min_players: u8,
    pub engine: &'static str,
    pub ai_topic_hint: &'static str,
    pub default_rounds: u8,
}

#[derive(Debug, Clone)]
pub struct FallbackQuizQuestion {
    pub question: String,
    pub options: Vec<String>,
    pub correct_index: usize,
    pub explanation: String,
}

#[derive(Debug, Clone)]
pub struct FallbackHintItem {
    pub answer: String,
    pub aliases: Vec<String>,
    pub hints: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct FallbackPartyRound {
    pub prompt: String,
    pub options: Vec<String>,
    pub commentary: String,
}

#[derive(Debug, Clone)]
pub struct FallbackChallengePrompt {
    pub prompt: String,
    pub tip: String,
    pub requires_image: bool,
}

pub const GAME_CATALOG: [GameCatalogItem; 100] = [
    // =========================================================================
    // 1..=30 : QUIZ (30 games — mix of "both" and "solo", min_players = 1)
    // =========================================================================
    GameCatalogItem {
        number: 1,
        id: "quiz_thai_food",
        name: "ควิซเซียนอาหารไทย",
        tagline: "วัดความรู้เมนูเด็ด เครื่องแกง และของอร่อย 4 ภาคทั่วไทย",
        emoji: "🍜",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามควิซสนุกๆ เกี่ยวกับอาหารไทย 4 ภาค วัตถุดิบ เครื่องแกง และเอกลักษณ์เมนูดังของไทย",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 2,
        id: "quiz_90s_thai",
        name: "ย้อนวันวานยุค 90 ไทย",
        tagline: "เทปคาสเซ็ต ขนมหน้าโรงเรียน และความทรงจำสุดคลาสสิกยุค 90",
        emoji: "📼",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามย้อนอดีตวัฒนธรรมป๊อปไทยยุค 90 เช่น เทปคาสเซ็ต ตู้โทรศัพท์หยอดเหรียญ การละเล่น และขนมวัยเด็ก",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 3,
        id: "quiz_thai_proverbs",
        name: "เซียนสำนวนสุภาษิตไทย",
        tagline: "ทายความหมายสำนวน คำพังเพย และสุภาษิตไทยใช้ให้เป๊ะ",
        emoji: "📜",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกี่ยวกับความหมายและสถานการณ์การใช้สำนวนไทย คำพังเพย และสุภาษิตไทยแบบเข้าใจง่ายสนุกๆ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 4,
        id: "quiz_77_provinces",
        name: "ตะลุย 77 จังหวัดทั่วไทย",
        tagline: "ภูมิศาสตร์ ของดี คำขวัญ และจุดเช็กอินเด็ดทุกภูมิภาค",
        emoji: "🗺️",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามความรู้รอบตัวเรื่อง 77 จังหวัดของไทย ภูมิภาค ที่ตั้ง ของดีประจำจังหวัด และแหล่งท่องเที่ยวขึ้นชื่อ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 5,
        id: "quiz_teen_slang",
        name: "สอบตกไหม? ศัพท์วัยรุ่นไทย",
        tagline: "อัปเดตคำฮิตโซเชียล ศัพท์แซ่บ และความหมายชวนขำ",
        emoji: "💬",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามความหมายศัพท์สแลงและคำฮิตบนโซเชียลไทยแบบสุภาพ ตลก และร่วมสมัย เหมาะเล่นได้ทุกวัย",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 6,
        id: "quiz_office_life",
        name: "ชีวิตชาวออฟฟิศสุดฮา",
        tagline: "ศัพท์ประชุม มารยาทอีเมล และเรื่องจริงที่มนุษย์เงินเดือนเข้าใจ",
        emoji: "💼",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามสนุกๆ เกี่ยวกับวัฒนธรรมออฟฟิศไทย คำย่อในที่ทำงาน การทำงานเป็นทีม และการสื่อสารในองค์กร",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 7,
        id: "quiz_personal_finance",
        name: "การเงินใกล้ตัวรู้ไว้ไม่พลาด",
        tagline: "ออมเงิน ดอกเบี้ยทบต้น และหลักวางแผนการเงินฉบับเข้าใจง่าย",
        emoji: "💰",
        category: "ทำงาน",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามหลักการเงินส่วนบุคคลพื้นฐานที่เป็นสากล เช่น เงินสำรองฉุกเฉิน ดอกเบี้ยทบต้น เงินเฟ้อ และการบริหารหนี้",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 8,
        id: "quiz_animal_world",
        name: "มหัศจรรย์โลกสัตว์ป่า",
        tagline: "ความลับน่าทึ่งของสัตว์บก สัตว์น้ำ และสัตว์แปลกทั่วโลก",
        emoji: "🐘",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกร็ดความรู้น่าทึ่งเกี่ยวกับสัตว์ป่า พฤติกรรม ถิ่นอาศัย และสถิติสุดแปลกของสัตว์ทั่วโลก",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 9,
        id: "quiz_thai_drama_cinema",
        name: "แฟนพันธุ์แท้หนัง-ละครไทย",
        tagline: "ฉากจำ อาชีพตัวละคร และเกร็ดวงการภาพยนตร์-ละครไทย",
        emoji: "🎬",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามสนุกๆ เกี่ยวกับวงการหนังไทย ละครไทย แนวเรื่องยอดฮิต ศัพท์กองถ่าย และวัฒนธรรมการดูหนังในไทย",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 10,
        id: "quiz_everyday_science",
        name: "วิทยาศาสตร์ใกล้ตัวชวนร้องอ๋อ",
        tagline: "ไขปริศนาปรากฏการณ์รอบบ้าน ครัว และธรรมชาติทุกวัน",
        emoji: "🔬",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามวิทยาศาสตร์ในชีวิตประจำวันที่เข้าใจง่ายและแม่นยำ เช่น การเดือดของน้ำ แสง เสียง อากาศ และร่างกายมนุษย์",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 11,
        id: "quiz_practical_english",
        name: "อังกฤษใช้จริงไม่งงฝรั่ง",
        tagline: "สำนวนสื่อสาร คำศัพท์ใช้งานบ่อย และกับดักคำที่มักแปลผิด",
        emoji: "🔤",
        category: "ทำงาน",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามภาษาอังกฤษที่ใช้จริงในชีวิตประจำวันและที่ทำงาน สำนวนที่คนไทยมักเข้าใจคลาดเคลื่อน พร้อมคำอธิบายชัดเจน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 12,
        id: "quiz_thai_history",
        name: "ย้อนรอยประวัติศาสตร์ไทย",
        tagline: "สุโขทัย อยุธยา ธนบุรี รัตนโกสินทร์ เกร็ดสำคัญที่ควรรู้",
        emoji: "🏛️",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามประวัติศาสตร์ไทยพื้นฐานที่ถูกต้องตามตำรา เช่น ราชธานีไทย โบราณสถาน และเหตุการณ์สำคัญทางประวัติศาสตร์",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 13,
        id: "quiz_thai_spelling",
        name: "คำไทยมักเขียนผิดชวนสะดุ้ง",
        tagline: "ทดสอบความเป๊ะสะกดคำไทยที่คนเกือบทั้งประเทศเผลอเขียนผิด",
        emoji: "✍️",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามให้เลือกคำภาษาไทยที่สะกดถูกต้องตามพจนานุกรมราชบัณฑิตยสถาน เฉพาะคำที่คนไทยมักเขียนสับสนบ่อยๆ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 14,
        id: "quiz_speed_math",
        name: "คิดเลขสายฟ้าลับสมอง",
        tagline: "บวกลบคูณหาร เปอร์เซ็นต์ลดราคา และโจทย์คำนวณไวในชีวิตจริง",
        emoji: "⚡",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งโจทย์คณิตคิดเร็วสนุกๆ ที่คำนวณในใจได้ เช่น เปอร์เซ็นต์ส่วนลด การหารค่าอาหาร และลำดับตัวเลข โดยคำตอบต้องถูกต้องแม่นยำ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 15,
        id: "quiz_brain_teaser",
        name: "เชาวน์ปัญญาหักมุม",
        tagline: "โจทย์ไหวพริบ ตรรกะ และคำถามชวนคิดนอกกรอบให้ร้องเฮ้ย",
        emoji: "🧠",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเชาวน์ปัญญาและตรรกะหักมุมที่สนุก ชัดเจน มีคำตอบเดียวสมเหตุสมผล พร้อมเฉลยชวนยิ้ม",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 16,
        id: "quiz_fruits_herbs",
        name: "ผลไม้และสมุนไพรพื้นบ้าน",
        tagline: "รู้จักสรรพคุณผักสวนครัว สมุนไพรไทย และผลไม้ตามฤดูกาล",
        emoji: "🥭",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกี่ยวกับผลไม้ไทย พืชผักสวนครัว และสมุนไพรพื้นบ้านของไทย ทั้งลักษณะ รสชาติ และประโยชน์ทั่วไป",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 17,
        id: "quiz_sports_mania",
        name: "ควิซกีฬามันส์ๆ รอบโลก",
        tagline: "ฟุตบอล แบดมินตัน วอลเลย์บอล มวยไทย และกติกากีฬาสุดฮิต",
        emoji: "⚽",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามกีฬาที่คนไทยนิยม เช่น ฟุตบอล แบดมินตัน วอลเลย์บอล มวยไทย บาสเกตบอล กติกาพื้นฐานและเกร็ดโอลิมปิก",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 18,
        id: "quiz_thai_music",
        name: "ควิซดนตรีและเพลงฮิต",
        tagline: "เครื่องดนตรีไทย-สากล แนวเพลง และเกร็ดวงการเพลงชวนเพลิน",
        emoji: "🎵",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเรื่องดนตรี เครื่องดนตรีไทยและสากล แนวเพลงลูกทุ่ง ป๊อป ร็อก และทฤษฎีดนตรีพื้นฐานแบบสนุกสนาน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 19,
        id: "quiz_tech_ai",
        name: "เทคโนโลยีและ AI ใกล้ตัว",
        tagline: "ศัพท์ดิจิทัล ความปลอดภัยไซเบอร์ และโลก AI ยุคใหม่",
        emoji: "🤖",
        category: "ทำงาน",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามความรู้เทคโนโลยี อินเทอร์เน็ต ความปลอดภัยทางไซเบอร์ และปัญญาประดิษฐ์ (AI) สำหรับผู้ใช้ทั่วไป",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 20,
        id: "quiz_world_travel",
        name: "ปักหมุดเที่ยวทั่วโลก",
        tagline: "เมืองหลวง สกุลเงิน แลนด์มาร์กดัง และวัฒนธรรมน่าไปเยือน",
        emoji: "✈️",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามท่องเที่ยวต่างประเทศ เมืองหลวง สัญลักษณ์สำคัญ อาหารประจำชาติ และมารยาทการเดินทางทั่วโลก",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 21,
        id: "quiz_traffic_driving",
        name: "กฎจราจรและขับรถปลอดภัย",
        tagline: "ป้ายเตือน เส้นจราจร และมารยาทบนท้องถนนที่คนขับรถต้องแม่น",
        emoji: "🚦",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามป้ายจราจรไทย เครื่องหมายบนพื้นทาง หลักขับขี่ปลอดภัย และสัญญาณไฟจราจรที่ผู้ใช้รถใช้ถนนควรรู้",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 22,
        id: "quiz_health_nutrition",
        name: "สุขภาพและการกินอย่างฉลาด",
        tagline: "สารอาหาร การนอน การออกกำลังกาย และความเชื่อเรื่องสุขภาพ",
        emoji: "🥗",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามความรู้โภชนาการและการดูแลสุขภาพพื้นฐานที่ถูกต้องตามหลักสากล เช่น วิตามิน การดื่มน้ำ และการพักผ่อน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 23,
        id: "quiz_coffee_cafe",
        name: "สายคาเฟ่และโลกกาแฟ",
        tagline: "เอสเปรสโซ ลาเต้ มัทฉะ เมล็ดคั่วอ่อน-เข้ม ทดสอบคอกาแฟตัวจริง",
        emoji: "☕",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกี่ยวกับเมนูกาแฟ ชา วิธีชง ระดับการคั่ว และวัฒนธรรมคาเฟ่ที่คอกาแฟและสายชิลชอบเล่น",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 24,
        id: "quiz_thai_culture",
        name: "วัฒนธรรมและวิถีไทยร่วมสมัย",
        tagline: "ประเพณีพื้นบ้าน งานหัตถกรรม และภูมิปัญญาไทยจากอดีตถึงปัจจุบัน",
        emoji: "🏮",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกี่ยวกับประเพณีไทย วัฒนธรรมท้องถิ่น ผ้าไทย เครื่องปั้นดินเผา และวันสำคัญทางวัฒนธรรมของไทย",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 25,
        id: "quiz_cute_pets",
        name: "ทาสหมาทาสแมวรู้จริงไหม",
        tagline: "ภาษากายเจ้าตูบ-เจ้านาย อาหารต้องห้าม และการดูแลสัตว์เลี้ยง",
        emoji: "🐾",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามน่ารักๆ และมีประโยชน์เกี่ยวกับพฤติกรรม การดูแล และอาหารที่ปลอดภัย/อันตรายสำหรับสุนัขและแมว",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 26,
        id: "quiz_home_hacks",
        name: "งานบ้านสุดโปรเคล็ดลับพ่อบ้านแม่บ้าน",
        tagline: "ซักผ้า ขจัดคราบ จัดเก็บอาหาร และทริกดูแลบ้านให้สะอาดกริ๊บ",
        emoji: "🧹",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเคล็ดลับงานบ้าน การดูแลเสื้อผ้า การถนอมอาหารในครัว และความปลอดภัยในบ้านที่ใช้ได้จริง",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 27,
        id: "quiz_space_stars",
        name: "ตะลุยอวกาศและดวงดาว",
        tagline: "ระบบสุริยะ ดาวเคราะห์ กาแล็กซี และภารกิจสำรวจจักรวาล",
        emoji: "🌌",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามดาราศาสตร์และอวกาศที่ถูกต้องและน่าตื่นเต้น เช่น ดาวเคราะห์ในระบบสุริยะ ดวงจันทร์ และปรากฏการณ์บนท้องฟ้า",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 28,
        id: "quiz_asian_street_food",
        name: "สตรีทฟู้ดเอเชียสุดฟิน",
        tagline: "ราเมง ต็อกบกกี เฝอ ติ่มซำ และเมนูริมทางขวัญใจสายกิน",
        emoji: "🥟",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกี่ยวกับอาหารริมทางและเมนูดังทั่วเอเชีย เช่น ญี่ปุ่น เกาหลี เวียดนาม จีน มาเลเซีย และสิงคโปร์",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 29,
        id: "quiz_social_etiquette",
        name: "มารยาทสังคมและไหวพริบ",
        tagline: "สถานการณ์ชวนเขิน งานสังคม และทักษะเข้าสังคมแบบมือโปร",
        emoji: "🤝",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามมารยาทการเข้าสังคม มารยาทบนโต๊ะอาหาร การพูดคุยกับผู้ใหญ่ และมารยาทการสื่อสารยุคดิจิทัล",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 30,
        id: "quiz_famous_years",
        name: "ทายยุคเหตุการณ์ดังในความทรงจำ",
        tagline: "สิ่งประดิษฐ์เปลี่ยนโลก เหตุการณ์ประวัติศาสตร์ และจุดเริ่มต้นของสิ่งใกล้ตัว",
        emoji: "📅",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "quiz",
        ai_topic_hint: "ตั้งคำถามเกี่ยวกับจุดกำเนิดสิ่งประดิษฐ์สำคัญและเหตุการณ์ระดับโลกหรือไทยที่เป็นที่รู้จักกว้างขวาง",
        default_rounds: 5,
    },

    // =========================================================================
    // 31..=45 : UNDERCOVER (15 games — play_mode = "group", min_players = 2)
    // =========================================================================
    GameCatalogItem {
        number: 31,
        id: "uc_street_food",
        name: "สายลับสตรีทฟู้ดไทย",
        tagline: "จับพิรุธคนได้เมนูข้างทางไม่เหมือนชาวบ้าน ใครเนียนใครโป๊ะรู้เลย!",
        emoji: "🍢",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำอาหารสตรีทฟู้ดไทยที่ใกล้เคียงกันมากสำหรับเกมสายลับ เช่น ผัดไทย/ผัดซีอิ๊ว หรือ ส้มตำ/ยำวุ้นเส้น",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 32,
        id: "uc_thai_fruits",
        name: "สายลับสวนผลไม้ไทย",
        tagline: "ใบ้รสชาติ สี เปลือก ให้เนียนที่สุด ระวังสายลับผลไม้ปลอมตัว!",
        emoji: "🍉",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำผลไม้ไทยหรือผลไม้ยอดฮิตที่ลักษณะหรือรสชาติคล้ายกัน เช่น เงาะ/ลิ้นจี่ หรือ ทุเรียน/ขนุน",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 33,
        id: "uc_thai_travel",
        name: "สายลับที่เที่ยวทั่วไทย",
        tagline: "ทะเล ภูเขา ตลาดน้ำ ใครกำลังใบ้ผิดจังหวัดต้องจับโหวตออก!",
        emoji: "🏝️",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำสถานที่ท่องเที่ยวดังในประเทศไทยที่บรรยากาศใกล้เคียงกัน เช่น ภูเก็ต/กระบี่ หรือ เชียงใหม่/เชียงราย",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 34,
        id: "uc_professions",
        name: "สายลับอาชีพสุดป่วน",
        tagline: "หมอ พยาบาล เชฟ บาริสต้า ใบ้หน้าที่ให้ชัดแต่อย่าให้สายลับจับทางได้",
        emoji: "👩‍⚕️",
        category: "ทำงาน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำอาชีพที่เกี่ยวข้องหรือมีลักษณะงานคล้ายกัน เช่น หมอ/พยาบาล หรือ โปรแกรมเมอร์/ดีไซเนอร์",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 35,
        id: "uc_animals",
        name: "สายลับสวนสัตว์โลก",
        tagline: "เสือหรือสิงโต? เป็ดหรือห่าน? ใครใบ้แปลกๆ เตรียมโดนสงสัย!",
        emoji: "🦁",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำสัตว์ที่รูปร่างหรือนิสัยใกล้เคียงกัน เช่น เสือ/สิงโต หรือ โลมา/วาฬ เล่นสนุกได้ทั้งครอบครัว",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 36,
        id: "uc_office_gear",
        name: "สายลับห้องประชุมออฟฟิศ",
        tagline: "อุปกรณ์โต๊ะทำงานและเครื่องเขียนที่คล้ายกันจนแทบแยกไม่ออก",
        emoji: "🖥️",
        category: "ทำงาน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำของใช้ในออฟฟิศหรืออุปกรณ์ทำงานที่ใกล้เคียงกัน เช่น ปากกา/ดินสอ หรือ คีย์บอร์ด/เมาส์",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 37,
        id: "uc_cafe_drinks",
        name: "สายลับบาร์เครื่องดื่มคาเฟ่",
        tagline: "ชาไทย ชาเขียว โกโก้ ลาเต้ ใครสั่งผิดแก้วเตรียมโดนจับโป๊ะ!",
        emoji: "🧋",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำเครื่องดื่มคาเฟ่หรือร้านน้ำยอดฮิตที่ชวนสับสน เช่น ชาไทย/ชานมไข่มุก หรือ ลาเต้/คาปูชิโน",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 38,
        id: "uc_home_items",
        name: "สายลับของใช้ในบ้าน",
        tagline: "ของใกล้ตัวในห้องนอน ห้องครัว และห้องนั่งเล่นที่ใบ้พลาดนิดเดียวเกมพลิก",
        emoji: "🛋️",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำของใช้ในบ้านที่ใช้งานใกล้กัน เช่น หมอน/ผ้าห่ม หรือ พัดลม/แอร์",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 39,
        id: "uc_sports",
        name: "สายลับสนามกีฬา",
        tagline: "แบดมินตันกับเทนนิส ฟุตบอลกับฟุตซอล ใครคือตัวปลอมในสนาม!",
        emoji: "🏀",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำชนิดกีฬาที่กติกาหรืออุปกรณ์คล้ายกัน เช่น แบดมินตัน/เทนนิส หรือ ฟุตบอล/ฟุตซอล",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 40,
        id: "uc_thai_festivals",
        name: "สายลับเทศกาลและประเพณีไทย",
        tagline: "สงกรานต์ ลอยกระทง ปีใหม่ ใบ้บรรยากาศให้เนียนอย่าเผลอหลุด!",
        emoji: "🎆",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำเทศกาลหรือวันสำคัญที่คนไทยคุ้นเคยและมีกิจกรรมคล้ายกัน เช่น สงกรานต์/ลอยกระทง หรือ ปีใหม่/ตรุษจีน",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 41,
        id: "uc_thai_desserts",
        name: "สายลับขนมไทยหวานหอม",
        tagline: "ทองหยิบ ทองหยอด ขนมชั้น บัวลอย ใครได้ขนมคนละจานต้องโดนเปิดโปง!",
        emoji: "🍡",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำขนมไทยที่วัตถุดิบหรือหน้าตาใกล้เคียงกัน เช่น ทองหยิบ/ทองหยอด หรือ ข้าวเหนียวมะม่วง/ข้าวเหนียวทุเรียน",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 42,
        id: "uc_vehicles",
        name: "สายลับยานพาหนะซิ่งทั่วไทย",
        tagline: "ตุ๊กตุ๊ก วินมอเตอร์ไซค์ รถเมล์ รถไฟฟ้า จับสายลับร่วมทริปให้ได้!",
        emoji: "🛺",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำยานพาหนะและการเดินทางในไทยที่คล้ายกัน เช่น ตุ๊กตุ๊ก/แท็กซี่ หรือ รถไฟ/รถไฟฟ้า",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 43,
        id: "uc_instruments",
        name: "สายลับวงดนตรี",
        tagline: "กีตาร์กับอูคูเลเล่ ระนาดกับขิม ใครเล่นผิดชิ้นในวงรู้เลย!",
        emoji: "🎸",
        category: "สร้างสรรค์",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำเครื่องดนตรีไทยหรือสากลที่มีวิธีเล่นใกล้กัน เช่น กีตาร์/อูคูเลเล่ หรือ ระนาดเอก/ขิม",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 44,
        id: "uc_school_subjects",
        name: "สายลับห้องเรียนในความทรงจำ",
        tagline: "คณิต วิทย์ ศิลปะ พละ ใครนั่งเรียนผิดคาบเตรียมโดนเพื่อนโหวตออก",
        emoji: "📚",
        category: "ความรู้",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำวิชาเรียนหรือกิจกรรมในโรงเรียนที่คล้ายกัน เช่น ฟิสิกส์/เคมี หรือ ศิลปะ/ดนตรี",
        default_rounds: 1,
    },
    GameCatalogItem {
        number: 45,
        id: "uc_supermarket",
        name: "สายลับซูเปอร์มาร์เก็ต",
        tagline: "ของกินของใช้บนชั้นวางที่หน้าตาคล้ายกันจนหยิบสลับบ้าน!",
        emoji: "🛒",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "undercover",
        ai_topic_hint: "สุ่มคู่คำสินค้าในซูเปอร์มาร์เก็ตที่อยู่ใกล้กันหรือใช้แทนกันได้ เช่น น้ำปลา/ซีอิ๊วขาว หรือ แชมพู/ครีมนวดผม",
        default_rounds: 1,
    },

    // =========================================================================
    // 46..=65 : HINT_RACE (20 games — mix of "both" and "solo", min_players = 1)
    // =========================================================================
    GameCatalogItem {
        number: 46,
        id: "hint_menu_ingredients",
        name: "ทายเมนูเด็ดจาก 5 ส่วนผสม",
        tagline: "เปิดวัตถุดิบทีละอย่าง ยิ่งทายถูกเร็วยิ่งได้คะแนนทะลุเพดาน!",
        emoji: "🍲",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อเมนูอาหารไทยจาก 5 คำใบ้ส่วนผสมและวิธีทำ ไล่จากคำใบ้ยากไปง่าย พร้อมคำตอบสั้นๆ และคำพ้องที่ยอมรับได้",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 47,
        id: "hint_province_motto",
        name: "ทายจังหวัดจากคำขวัญและของดี",
        tagline: "เปิดเบาะแสของดีและจุดเด่นทีละขั้น ทายชื่อจังหวัดไทยให้ไว!",
        emoji: "🏞️",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อจังหวัดในประเทศไทยจาก 5 คำใบ้ ไล่จากภูมิภาค ของดี อาหารขึ้นชื่อ และแลนด์มาร์กดัง",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 48,
        id: "hint_job_tools",
        name: "ทายอาชีพจากอุปกรณ์คู่ใจ",
        tagline: "เห็นแค่เครื่องมือกับกิจวัตรประจำวัน เดาออกไหมว่าคืออาชีพอะไร?",
        emoji: "🔧",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่ออาชีพจาก 5 คำใบ้เกี่ยวกับอุปกรณ์คู่ใจ สถานที่ทำงาน และภารกิจประจำวัน ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 49,
        id: "hint_animal_habits",
        name: "ทายสัตว์ปริศนาจากนิสัย",
        tagline: "ฟังนิสัยแปลกๆ และถิ่นอาศัย 5 ขั้น แล้วเดาว่าคือสัตว์ตัวไหน",
        emoji: "🦉",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อสัตว์จาก 5 คำใบ้เรื่องพฤติกรรม อาหาร ถิ่นอาศัย และเอกลักษณ์ร่างกาย ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 50,
        id: "hint_thai_idiom",
        name: "ทายสำนวนไทยจาก 5 คำใบ้",
        tagline: "เปิดคำใบ้สถานการณ์ทีละบรรทัด แล้วชิงตอบสำนวนไทยให้ตรงเป๊ะ",
        emoji: "🪶",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายสำนวนไทยคุ้นหูจาก 5 คำใบ้สถานการณ์และองค์ประกอบในสำนวน ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 51,
        id: "hint_home_objects",
        name: "ทายสิ่งของในบ้านใกล้ตัว",
        tagline: "ของที่คุณหยิบใช้แทบทุกวัน แต่พอใบ้ทีละนิดจะนึกออกไวแค่ไหน!",
        emoji: "🪑",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อสิ่งของทั่วไปในบ้านจาก 5 คำใบ้รูปทรง วัสดุ ห้องที่วาง และการใช้งาน ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 52,
        id: "hint_thai_landmarks",
        name: "ทายแลนด์มาร์กดังในไทย",
        tagline: "เกาะดัง ดอยสูง วัดงาม ตลาดเด็ด เปิด 5 เบาะแสชวนออกทริป",
        emoji: "🏯",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อสถานที่ท่องเที่ยวหรือแลนด์มาร์กชื่อดังในไทยจาก 5 คำใบ้ ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 53,
        id: "hint_mystery_fruit",
        name: "ทายผลไม้ปริศนาจากรสชาติ",
        tagline: "เปลือก สี กลิ่น ฤดูกาล เปิดทีละข้อแล้วทายชื่อผลไม้ให้แม่น",
        emoji: "🍍",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อผลไม้จาก 5 คำใบ้เรื่องฤดูกาล เปลือก เนื้อ รสชาติ และเมนูแปรรูป ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 54,
        id: "hint_movie_plot",
        name: "ทายแนวหนังจากเรื่องย่อสุดปั่น",
        tagline: "เปิดเบาะแสฉากเด็ดและพล็อตชวนลุ้น ทายให้ถูกว่าเป็นหนังแนวไหนหรือเรื่องอะไร",
        emoji: "🎞️",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายแนวภาพยนตร์หรือเรื่องราวคลาสสิกที่เป็นสาธารณสมบัติจาก 5 คำใบ้พล็อตเรื่องแบบตลกชวนคิด",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 55,
        id: "hint_appliances",
        name: "ทายเครื่องใช้ไฟฟ้าในบ้าน",
        tagline: "เสียบปลั๊กทุกวันแต่ใบ้แบบลับๆ ใครเดาได้ก่อนคำใบ้ที่ 3 คือเทพ!",
        emoji: "🔌",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อเครื่องใช้ไฟฟ้าในบ้านจาก 5 คำใบ้เรื่องเสียง การทำงาน ห้องที่ใช้ และประโยชน์ ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 56,
        id: "hint_thai_sweets",
        name: "ทายขนมหวานไทยชวนหิว",
        tagline: "กะทิ ใบเตย น้ำตาลโตนด เปิดทีละคำใบ้จนท้องร้อง!",
        emoji: "🍮",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อขนมหวานไทยจาก 5 คำใบ้ส่วนผสม สีสัน ห่อบรรจุ และรสชาติ ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 57,
        id: "hint_sport_rules",
        name: "ทายกีฬาจากกติกาและสนาม",
        tagline: "จำนวนผู้เล่น อุปกรณ์ และการนับแต้ม ทายชื่อกีฬาให้ทันก่อนใคร",
        emoji: "🏸",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อชนิดกีฬาจาก 5 คำใบ้เรื่องสนาม กติกา อุปกรณ์ และวิธีทำคะแนน ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 58,
        id: "hint_world_festivals",
        name: "ทายเทศกาลดังทั่วโลก",
        tagline: "โคมไฟ ดอกไม้ไฟ ชุดประจำชาติ และธรรมเนียมสุดคึกคักรอบโลก",
        emoji: "🎉",
        category: "ความรู้",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อเทศกาลสำคัญของไทยและทั่วโลกจาก 5 คำใบ้เรื่องช่วงเวลา กิจกรรม และสัญลักษณ์เด่น",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 59,
        id: "hint_thai_spoonerism",
        name: "ทายคำผวนชวนงงฮาลั่น",
        tagline: "สลับเสียงหัวท้ายแบบสุภาพชวนขำ สมองไวแค่ไหนมาลอง!",
        emoji: "😜",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายคำผวนภาษาไทยแบบสุภาพน่ารักและตลกจาก 5 คำใบ้ความหมายและเสียงผวน ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 60,
        id: "hint_popular_acronyms",
        name: "ทายคำย่อสุดฮิตยุคโซเชียล",
        tagline: "WFH, FYI, OOTD และคำย่อฮิตในแชทและออฟฟิศ ทายความหมายให้เป๊ะ",
        emoji: "🏷️",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายคำย่อภาษาอังกฤษหรือไทยยอดฮิตที่ใช้บ่อยในแชทและที่ทำงานจาก 5 คำใบ้ ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 61,
        id: "hint_country_food",
        name: "ทายประเทศจากจานเด็ดประจำชาติ",
        tagline: "ไล่ชื่อเมนูดังและวัตถุดิบประจำถิ่น แล้วทายให้ถูกว่าประเทศไหน!",
        emoji: "🍣",
        category: "ความรู้",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อประเทศจาก 5 คำใบ้อาหาร เครื่องดื่ม และวัฒนธรรมการกินประจำชาติ ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 62,
        id: "hint_thai_flowers",
        name: "ทายดอกไม้ไทยหอมละมุน",
        tagline: "สี กลิ่น ความหมายมงคล และฤดูบาน ชวนทายชื่อดอกไม้คู่บ้านไทย",
        emoji: "🌺",
        category: "ครอบครัว",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อดอกไม้ไทยหรือดอกไม้ที่คนไทยคุ้นเคยจาก 5 คำใบ้สี กลิ่น การใช้งาน และความหมายมงคล",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 63,
        id: "hint_popular_drinks",
        name: "ทายเครื่องดื่มยอดฮิตดับกระหาย",
        tagline: "หวาน มัน เปรี้ยว ซ่า เปิดสูตรทีละนิดแล้วทายเมนูน้ำให้ถูก!",
        emoji: "🥤",
        category: "เพื่อน",
        play_mode: "solo",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่อเครื่องดื่มยอดฮิตในร้านน้ำและคาเฟ่ไทยจาก 5 คำใบ้ส่วนผสม สี และรสชาติ ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 64,
        id: "hint_digital_jobs",
        name: "ทายอาชีพยุคดิจิทัลและครีเอเตอร์",
        tagline: "สายโค้ด สายคอนเทนต์ สายดาต้า เดาชื่ออาชีพยุคใหม่จาก 5 เบาะแส",
        emoji: "💻",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาทายชื่ออาชีพยุคดิจิทัลและเทคโนโลยีจาก 5 คำใบ้เครื่องมือ ทักษะ และผลลัพธ์งาน ไล่จากยากไปง่าย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 65,
        id: "hint_folk_riddles",
        name: "ปริศนาคำทายพื้นบ้าน (อะไรเอ่ย)",
        tagline: "อะไรเอ่ยสุดคลาสสิกภูมิปัญญาไทย ปรับให้ทายสนุกได้ทุกวัย!",
        emoji: "🌾",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "hint_race",
        ai_topic_hint: "สร้างปริศนาคำทายพื้นบ้านไทยแนว 'อะไรเอ่ย' พร้อมคำใบ้เพิ่มเติมครบ 5 ขั้น ไล่จากคล้องจองลึกลับไปจนเดาได้ง่าย",
        default_rounds: 3,
    },

    // =========================================================================
    // 66..=85 : PARTY_VOTE (20 games — mix of "group" (min=2) and "both" (min=1))
    // =========================================================================
    GameCatalogItem {
        number: 66,
        id: "vote_would_you_rather",
        name: "เลือกอะไรดีสายฮา",
        tagline: "2 ทางเลือกสุดปั่นที่เลือกอันไหนก็ขำ ดูซิว่าใจตรงกับคนส่วนใหญ่ไหม",
        emoji: "⚖️",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์โหวตแนว Would You Rather ภาษาไทยสุดฮาและสร้างสรรค์ 2-4 ตัวเลือก พร้อมคอมเมนต์แซวขำๆ หลังเฉลย",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 67,
        id: "vote_most_likely",
        name: "ใครในกลุ่มน่าจะ...",
        tagline: "โหวตแฉเบาๆ สไตล์เพื่อนซี้ ใครในห้องนี้เข้าข่ายที่สุด!",
        emoji: "👑",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์โหวตขำๆ แนว 'ในกลุ่มนี้ใครน่าจะ...' แบบอบอุ่นไม่แรงเกินไป พร้อมตัวเลือกนิสัย/บทบาทให้กดโหวตสนุกๆ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 68,
        id: "vote_desert_island",
        name: "ผจญภัยเอาตัวรอดเกาะร้าง",
        tagline: "ติดเกาะกลางทะเล! โหวตตัดสินใจทุกช็อตว่าจะรอดหรือจะฮา",
        emoji: "🌴",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างสถานการณ์จำลองเอาตัวรอดบนเกาะร้างต่อเนื่อง 5 ด่าน มีตัวเลือกการตัดสินใจ 3-4 ทางและผลลัพธ์สุดฮา",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 69,
        id: "vote_haunted_house",
        name: "ผจญภัยบ้านผีสิงฮาเฮ",
        tagline: "หลอนนิด ขำหนัก! โหวตทางเดินในคฤหาสน์ปริศนาว่าจะรอดกี่คน",
        emoji: "👻",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างฉากผจญภัยบ้านผีสิงแนวตลกปนลุ้น (ไม่สยองขวัญรุนแรง) ให้เลือกทางรอด 3-4 ตัวเลือก พร้อมคอมเมนต์หักมุมสุดขำ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 70,
        id: "vote_squad_mind",
        name: "ทายใจแก๊งเพื่อนซี้",
        tagline: "เช็กเคมีแก๊งเพื่อน ตอบให้ตรงกันในสถานการณ์ประจำวันสุดฮิต",
        emoji: "🫶",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างคำถามทายใจแก๊งเพื่อนเกี่ยวกับนัดเที่ยว กินข้าว ถ่ายรูป และพฤติกรรมเวลาอยู่ด้วยกัน ให้โหวตเช็กความใจตรงกัน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 71,
        id: "vote_family_mind",
        name: "ทายใจคนในครอบครัว",
        tagline: "คำถามอบอุ่นเรียกรอยยิ้ม เล่นได้ทุกวัยในบ้านตั้งแต่หลานยันคุณตา",
        emoji: "🏡",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างคำถามโหวตอบอุ่นน่ารักสำหรับครอบครัวไทย เช่น วันหยุดของบ้าน เมนูโปรดบ้านเรา และกิจกรรมทำร่วมกัน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 72,
        id: "vote_office_drama",
        name: "ดราม่าออฟฟิศเลือกทางรอด",
        tagline: "เดดไลน์จ่อ ประชุมซ้อน กาแฟหมด เลือกทางรับมือแบบมือโปรหรือสายกาว!",
        emoji: "🧯",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างสถานการณ์จำลองในที่ทำงานสุดปั่นแต่สมจริง เช่น งานด่วนเย็นวันศุกร์ ไฟล์หายก่อนพรีเซนต์ ให้เลือกวิธีแก้ปัญหา",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 73,
        id: "vote_dream_trip",
        name: "ทริปในฝันโหวตให้จบ",
        tagline: "ทะเล ภูเขา ญี่ปุ่น คาเฟ่ โหวตแผนเที่ยวจนได้ทริปที่ไม่มีใครงอน!",
        emoji: "🧳",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างรอบโหวตวางแผนทริปท่องเที่ยวร่วมกัน ตั้งแต่จุดหมาย สไตล์ที่พัก กิจกรรมหลัก ไปจนงบประมาณและของฝาก",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 74,
        id: "vote_dinner_decider",
        name: "มื้อเย็นนี้กินอะไรดี",
        tagline: "จบปัญหาระดับชาติ 'อะไรก็ได้' ด้วยการโหวตสุดสนุกจนได้ร้าน!",
        emoji: "🍽️",
        category: "ครอบครัว",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างคำถามโหวตช่วยตัดสินใจมื้ออาหาร ตั้งแต่ประเภทอาหาร รสชาติ บรรยากาศร้าน ไปจนของหวานตบท้าย",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 75,
        id: "vote_spender_vs_saver",
        name: "สายเปย์หรือสายประหยัด",
        tagline: "เช็กนิสัยการใช้เงินผ่านโจทย์ชอปปิง โปรลดราคา และของมันต้องมี",
        emoji: "💳",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์โหวตสนุกๆ สะท้อนสไตล์การใช้เงินและชอปปิง เช่น แฟลชเซลล์ เที่ยวหรู vs ประหยัด พร้อมคอมเมนต์แซวเบาๆ",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 76,
        id: "vote_lottery_30m",
        name: "ถ้าถูกหวย 30 ล้านจะทำอะไร",
        tagline: "ซ้อมเป็นเศรษฐีใหม่! โหวตแผนใช้เงิน 30 ล้านให้สะใจใน 5 ขั้น",
        emoji: "🎟️",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์สมมติสนุกๆ เมื่อถูกรางวัลใหญ่ 30 ล้านบาท เช่น สิ่งแรกที่ซื้อ จะบอกใครก่อน และแผนชีวิตหลังมีเงิน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 77,
        id: "vote_superpower",
        name: "ซูเปอร์พาวเวอร์เลือกได้ 1 อย่าง",
        tagline: "หายตัว อ่านใจ วาร์ปไปทำงาน หรือหยุดเวลา เลือกพลังเดียวแล้วลุย!",
        emoji: "🦸",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์เลือกพลังวิเศษพร้อมเงื่อนไขหักมุมขำๆ ให้เลือก 1 อย่าง พร้อมวิเคราะห์นิสัยผู้เล่นแบบสนุกสนาน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 78,
        id: "vote_mini_detective",
        name: "คดีสืบสวนสั้นสไตล์นักสืบ AI",
        tagline: "สวมบทนักสืบอ่านเบาะแสแล้วโหวตชี้ตัวผู้ต้องสงสัยตัวจริง!",
        emoji: "🕵️",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างคดีสืบสวนสั้นๆ สนุกๆ (แนวขโมยเค้ก ของหายในออฟฟิศ ไม่รุนแรง) ให้ผู้เล่นโหวตเลือกผู้ต้องสงสัยหรือหลักฐานเด็ด",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 79,
        id: "vote_peak_habits",
        name: "โหวตนิสัยสุดพีกใครเคยเป็น",
        tagline: "ตั้งปลุก 7 รอบ เปิดตู้เย็นดูเฉยๆ สารภาพความพีกที่ทำกันทั้งบ้าน!",
        emoji: "🫣",
        category: "ทายใจ/ฮา",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างคำถามโหวตพฤติกรรมสุดฮาในชีวิตประจำวันที่คนไทยแทบทุกคนเคยทำ ให้กดโหวตระดับความเหมือนตัวเอง",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 80,
        id: "vote_weekend_vibe",
        name: "ชีวิตวันหยุดเลือกแบบไหนดี",
        tagline: "นอนเปื่อย ดูซีรีส์ ออกไปคาเฟ่ หรือจัดบ้าน เช็กโหมดวันหยุดของคุณ",
        emoji: "🛌",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์โหวตสไตล์การใช้เวลาวันเสาร์-อาทิตย์ ตั้งแต่ตื่นเช้า กิจกรรมบ่าย ไปจนคืนวันอาทิตย์",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 81,
        id: "vote_save_world_5m",
        name: "ภารกิจกู้โลกใน 5 นาที",
        tagline: "อุกกาบาตมา เอเลี่ยนทักแชท! โหวตแผนกู้โลกสุดปั่นให้ทันเวลา",
        emoji: "☄️",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างภารกิจกู้โลกแนวไซไฟคอมเมดี้ 5 ด่านเร่งด่วน มีตัวเลือกแผนรับมือสุดสร้างสรรค์และคอมเมนต์สรุปผลสุดฮา",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 82,
        id: "vote_ayutthaya_portal",
        name: "หลุดมิติไปยุคอยุธยา",
        tagline: "ย้อนเวลาไปกรุงศรีแบบไม่ทันตั้งตัว จะพกอะไรและเอาตัวรอดยังไงดี!",
        emoji: "⛵",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "party_vote",
        ai_topic_hint: "สร้างเนื้อเรื่องย้อนเวลาหลุดมิติไปยุคกรุงศรีอยุธยาแบบสนุกสนานสุภาพ ให้โหวตเลือกอาชีพ ของที่พกไป และการปรับตัว",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 83,
        id: "vote_open_cafe_together",
        name: "เปิดร้านคาเฟ่ด้วยกันจะรอดไหม",
        tagline: "หุ้นกันเปิดร้าน! โหวตคอนเซ็ปต์ เมนูซิกเนเจอร์ และแผนเรียกลูกค้า",
        emoji: "🥐",
        category: "ทำงาน",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างสถานการณ์จำลองช่วยกันวางแผนเปิดร้านคาเฟ่ในฝัน ตั้งแต่ทำเล คอนเซ็ปต์ เมนูเด็ด และโปรเปิดร้าน",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 84,
        id: "vote_food_taste",
        name: "ศึกทายรสนิยมการกินสุดเดือด",
        tagline: "กะเพราใส่ถั่วฝักยาวไหม? พิซซ่าใส่สับปะรดได้เปล่า? โหวตชี้ชะตา!",
        emoji: "🌶️",
        category: "ทายใจ/ฮา",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างศึกโหวตดีเบตเรื่องอาหารยอดฮิตของคนไทยแบบขำๆ เช่น กะเพราใส่ถั่วฝักยาว ส้มตำปลาร้า vs ไทย ก๋วยเตี๋ยวเส้นไหนเด็ดสุด",
        default_rounds: 5,
    },
    GameCatalogItem {
        number: 85,
        id: "vote_telepathy_test",
        name: "บททดสอบความใจตรงกัน",
        tagline: "โจทย์คำถามสั้นๆ วัดพลังโทรจิตว่าทุกคนในห้องจะกดตัวเลือกเดียวกันไหม!",
        emoji: "✨",
        category: "เพื่อน",
        play_mode: "group",
        min_players: 2,
        engine: "party_vote",
        ai_topic_hint: "สร้างโจทย์ทดสอบความใจตรงกันแบบกระชับ เช่น สีแรกที่นึกถึง ฤดูที่ชอบ ของหวานที่สั่งก่อน เพื่อให้กลุ่มลุ้นว่าจะโหวตเหมือนกันไหม",
        default_rounds: 5,
    },

    // =========================================================================
    // 86..=100 : CREATIVE_CHALLENGE (15 games — mix of "both"/"solo", min=1)
    // =========================================================================
    GameCatalogItem {
        number: 86,
        id: "create_two_line_poem",
        name: "แต่งกลอน 2 วรรคชิงแชมป์",
        tagline: "รับโจทย์สุดกวนแล้วแต่งกลอนคล้องจอง 2 วรรค ให้ AI ให้คะแนนความเฉียบ!",
        emoji: "✒️",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์แต่งกลอนหรือคำคล้องจองไทยสั้นๆ 2 วรรคในหัวข้อใกล้ตัวสนุกๆ เช่น เงินเดือน อาหารเย็น หรือวันฝนตก",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 87,
        id: "create_funny_caption",
        name: "ตั้งแคปชันฮาๆ เรียกไลก์",
        tagline: "รับสถานการณ์แล้วปั่นแคปชันสุดเฉียบ ประชันความครีเอทีฟกับ BC AI",
        emoji: "😂",
        category: "ทายใจ/ฮา",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์ให้ผู้เล่นแต่งแคปชันโพสต์โซเชียลสั้นๆ แนวน่ารักตลกหรือกวนเบาๆ ตามสถานการณ์ที่กำหนด",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 88,
        id: "create_shop_name",
        name: "คิดชื่อร้านให้ปังตั้งแต่เปิด",
        tagline: "ได้ประเภทธุรกิจแล้วตั้งชื่อร้านให้จำง่าย ติดหู และอยากเข้าร้านทันที!",
        emoji: "🏪",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์ให้คิดชื่อร้านค้า คาเฟ่ หรือแบรนด์ไทยสไตล์เก๋ๆ จำง่าย ตามประเภทธุรกิจและกลุ่มลูกค้าที่กำหนด",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 89,
        id: "create_late_excuse",
        name: "ข้ออ้างมาสายแบบสร้างสรรค์",
        tagline: "แต่งข้ออ้างมาสายสุดล้ำระดับตำนานที่หัวหน้าฟังแล้วหลุดขำ!",
        emoji: "⏰",
        category: "ทำงาน",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์แต่งข้ออ้างมาสายหรือส่งงานช้าแนวแฟนตาซีตลกขำขันแบบสุภาพ ให้ผู้เล่นโชว์จินตนาการ",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 90,
        id: "create_monday_quote",
        name: "คำคมวันจันทร์แก้ง่วง",
        tagline: "ปั้นคำคมเติมไฟหรือปลอบใจชาวทำงานเช้าวันจันทร์ให้ตาสว่าง!",
        emoji: "🌅",
        category: "ทำงาน",
        play_mode: "solo",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์แต่งคำคมปลุกใจหรือคำคมขำๆ สำหรับเช้าวันจันทร์และวันที่งานยุ่ง เพื่อให้กำลังใจตัวเองและเพื่อนร่วมงาน",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 91,
        id: "create_wacky_slogan",
        name: "ตั้งสโลแกนขายของสุดกาว",
        tagline: "หยิบสินค้าธรรมดามาปั้นสโลแกนขายให้เวอร์วังจนคนต้องรีบ CF!",
        emoji: "📣",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์ให้คิดสโลแกนโฆษณาสุดครีเอทีฟสำหรับสินค้าธรรมดาหรือของประหลาดให้ฟังดูน่าซื้อแบบขำๆ",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 92,
        id: "create_turn_bad_funny",
        name: "เปลี่ยนเรื่องซวยให้เป็นเรื่องตลก",
        tagline: "เจอเรื่องเฟลเบาๆ แล้วพลิกมุมคิดให้กลายเป็นมุกขำพลังบวก!",
        emoji: "🎭",
        category: "ทายใจ/ฮา",
        play_mode: "solo",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์สถานการณ์เฟลเล็กๆ ในชีวิตประจำวัน เช่น ลืมพกร่ม ทำขนมหก แล้วให้ผู้เล่นเขียนมุมมองปลอบใจแบบตลกอบอุ่น",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 93,
        id: "create_emoji_story",
        name: "แปลอารมณ์และแต่งเรื่องจากอีโมจิ",
        tagline: "รับชุดอีโมจิลึกลับ 4 ตัว แล้วผูกเป็นเรื่องสั้นสุดพีกใน 1-2 ประโยค",
        emoji: "🧩",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "กำหนดชุดอีโมจิ 4 ตัวที่ดูไม่เข้ากัน แล้วให้ผู้เล่นแต่งเรื่องสั้นหรือประโยคเชื่อมโยงทั้งหมดอย่างสร้างสรรค์",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 94,
        id: "create_one_line_intro",
        name: "แนะนำตัวเองใน 1 ประโยคสุดปัง",
        tagline: "สวมบทบาทสุดแปลกแล้วเปิดตัวใน 1 ประโยคให้คนทั้งห้องจำไม่ลืม!",
        emoji: "🌟",
        category: "เพื่อน",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์ให้แนะนำตัวใน 1 ประโยคสุดประทับใจหรือสุดฮาตามสถานการณ์สมมติ เช่น เข้าแก๊งใหม่ หรือเปิดตัวซูเปอร์ฮีโร่ไทย",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 95,
        id: "create_fusion_menu",
        name: "คิดเมนูฟิวชันใหม่ให้เชฟอึ้ง",
        tagline: "จับคู่วัตถุดิบสุดคาดไม่ถึงมาสร้างเมนูฟิวชันพร้อมชื่อสุดหรู!",
        emoji: "👨‍🍳",
        category: "สร้างสรรค์",
        play_mode: "solo",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์จับคู่วัตถุดิบไทยกับอาหารนานาชาติให้ผู้เล่นคิดชื่อเมนูฟิวชันและคำอธิบายรสชาติชวนชิม",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 96,
        id: "create_warm_blessing",
        name: "เขียนคำอวยพรอบอุ่นให้คนข้างๆ",
        tagline: "ส่งต่อพลังบวกด้วยคำอวยพรสั้นๆ จากใจที่อ่านแล้วต้องยิ้มแก้มปริ",
        emoji: "💐",
        category: "ครอบครัว",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งโจทย์เขียนคำอวยพรหรือข้อความให้กำลังใจสุดอบอุ่นสำหรับคนในครอบครัว เพื่อน หรือเพื่อนร่วมงานในโอกาสต่างๆ",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 97,
        id: "create_word_chain",
        name: "แต่งประโยคต่อคำสุดล้ำ",
        tagline: "รับ 3 คำบังคับสุดไม่เข้าพวก แล้วร้อยเป็นประโยคเดียวให้เนียนที่สุด!",
        emoji: "🔗",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "กำหนดคำไทยบังคับ 3 คำที่ดูต่างขั้วกัน แล้วให้ผู้เล่นแต่งประโยคสั้นๆ ที่ใช้ครบทั้ง 3 คำอย่างเนียนและสนุก",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 98,
        id: "create_photo_red",
        name: "ภารกิจถ่ายรูปของสีแดงใกล้ตัว",
        tagline: "มองรอบตัวแล้วถ่ายภาพสิ่งของสีแดงหรือธีมสีสดส่งให้ BC AI ตรวจให้คะแนน!",
        emoji: "🔴",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งภารกิจถ่ายภาพสิ่งของสีแดงหรือวัตถุตามสี/รูปทรงที่อยู่รอบตัวผู้เล่น (requires_image=true) พร้อมให้ BC AI ใช้ Vision ตรวจและคอมเมนต์",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 99,
        id: "create_photo_fav_corner",
        name: "ภารกิจถ่ายรูปมุมโปรดตอนนี้",
        tagline: "แชร์มุมโต๊ะทำงาน มุมพักผ่อน หรือวิวข้างหน้าต่าง ให้ AI รีวิวฟีลภาพ!",
        emoji: "📸",
        category: "สร้างสรรค์",
        play_mode: "solo",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งภารกิจถ่ายภาพมุมโปรด โต๊ะทำงาน หรือบรรยากาศรอบตัวตอนนี้ (requires_image=true) ให้ BC AI ใช้ Vision ชื่นชมและให้คะแนนองค์ประกอบภาพ",
        default_rounds: 3,
    },
    GameCatalogItem {
        number: 100,
        id: "create_photo_food_drink",
        name: "ภารกิจถ่ายรูปอาหารหรือเครื่องดื่มตรงหน้า",
        tagline: "อวดแก้วน้ำ ขนม หรือจานอร่อยตรงหน้า ให้เชฟ BC AI รีวิวความน่ากิน!",
        emoji: "🍱",
        category: "สร้างสรรค์",
        play_mode: "both",
        min_players: 1,
        engine: "creative_challenge",
        ai_topic_hint: "ตั้งภารกิจถ่ายภาพอาหาร ขนม หรือเครื่องดื่มที่อยู่ตรงหน้าผู้เล่น (requires_image=true) ให้ BC AI ใช้ Vision รีวิวความน่ากินแบบอบอุ่นสนุกๆ",
        default_rounds: 3,
    },
];

// =============================================================================
// Deterministic Seed Mixing & Lookup / Filter / Randomizer API
// =============================================================================

struct SeedRng {
    state: u64,
}

impl SeedRng {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn shuffle<T>(&mut self, items: &mut [T]) {
        let len = items.len();
        if len <= 1 {
            return;
        }
        for i in (1..len).rev() {
            let j = (self.next_u64() as usize) % (i + 1);
            items.swap(i, j);
        }
    }
}

fn fnv1a_64(input: &str) -> u64 {
    let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
    for byte in input.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    }
    hash
}

pub fn find_game_by_id(id: &str) -> Option<&'static GameCatalogItem> {
    let key = id.trim();
    GAME_CATALOG.iter().find(|item| item.id == key)
}

pub fn filter_catalog(
    mode: Option<&str>,
    category: Option<&str>,
    query: Option<&str>,
) -> Vec<&'static GameCatalogItem> {
    let mode_norm = mode
        .map(|m| m.trim().to_ascii_lowercase())
        .filter(|m| !m.is_empty());
    let category_norm = category
        .map(str::trim)
        .filter(|c| !c.is_empty() && *c != "all" && *c != "ทั้งหมด");
    let query_norm = query
        .map(|q| q.trim().to_lowercase())
        .filter(|q| !q.is_empty());

    GAME_CATALOG
        .iter()
        .filter(|game| {
            let mode_ok = match mode_norm.as_deref() {
                Some("solo") => game.play_mode == "solo" || game.play_mode == "both",
                Some("group") => game.play_mode == "group" || game.play_mode == "both",
                Some("both") => game.play_mode == "both",
                _ => true,
            };
            if !mode_ok {
                return false;
            }

            if let Some(cat) = category_norm {
                if game.category != cat {
                    return false;
                }
            }

            if let Some(ref q) = query_norm {
                let num_str = game.number.to_string();
                let matched = game.name.to_lowercase().contains(q)
                    || game.tagline.to_lowercase().contains(q)
                    || game.id.to_lowercase().contains(q)
                    || game.category.to_lowercase().contains(q)
                    || game.engine.to_lowercase().contains(q)
                    || num_str == *q;
                if !matched {
                    return false;
                }
            }

            true
        })
        .collect()
}

pub fn pick_random_game(
    mode: &str,
    category: Option<&str>,
    exclude_ids: &[String],
    seed: u64,
) -> &'static GameCatalogItem {
    let mut candidates = filter_catalog(Some(mode), category, None);
    if candidates.is_empty() {
        candidates = filter_catalog(Some(mode), None, None);
    }
    if candidates.is_empty() {
        candidates = GAME_CATALOG.iter().collect();
    }

    let fresh: Vec<&'static GameCatalogItem> = candidates
        .iter()
        .copied()
        .filter(|g| !exclude_ids.iter().any(|ex| ex == g.id))
        .collect();

    let pool = if fresh.is_empty() { candidates } else { fresh };
    let mut rng = SeedRng::new(seed ^ fnv1a_64(mode));
    let idx = (rng.next_u64() as usize) % pool.len();
    pool[idx]
}

fn select_prioritized_indices(
    tier1: Vec<usize>,
    tier2: Vec<usize>,
    tier3: Vec<usize>,
    count: usize,
    seed: u64,
) -> Vec<usize> {
    if count == 0 {
        return Vec::new();
    }
    let mut rng = SeedRng::new(seed);
    let mut t1 = tier1;
    let mut t2 = tier2;
    let mut t3 = tier3;
    rng.shuffle(&mut t1);
    rng.shuffle(&mut t2);
    rng.shuffle(&mut t3);

    let mut combined = Vec::with_capacity(t1.len() + t2.len() + t3.len());
    combined.extend(t1);
    combined.extend(t2);
    combined.extend(t3);

    if combined.is_empty() {
        return Vec::new();
    }

    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        out.push(combined[i % combined.len()]);
    }
    out
}

// =============================================================================
// Curated Thai Fallback Bank 1: QUIZ (60 distinct questions — 2 per quiz game)
// =============================================================================

struct QuizSeed {
    game_id: &'static str,
    category: &'static str,
    question: &'static str,
    options: [&'static str; 4],
    correct_index: usize,
    explanation: &'static str,
}

const QUIZ_BANK: &[QuizSeed] = &[
    // #1 quiz_thai_food
    QuizSeed {
        game_id: "quiz_thai_food",
        category: "ครอบครัว",
        question: "เครื่องเทศและสมุนไพรคู่หูหลักที่ให้กลิ่นหอมเป็นเอกลักษณ์ใน 'ต้มยำกุ้ง' คือชุดใด?",
        options: [
            "ข่า ตะไคร้ ใบมะกรูด",
            "อบเชย โป๊ยกั๊ก พริกไทยดำ",
            "ขมิ้นชัน ยี่หร่า ลูกผักชี",
            "ใบโหระพา กระชาย พริกไทยอ่อน",
        ],
        correct_index: 0,
        explanation: "ต้มยำกุ้งขาดชุดเครื่องต้มยำ 'ข่า ตะไคร้ ใบมะกรูด' ไม่ได้เลย ให้กลิ่นหอมสดชื่นเฉพาะตัว",
    },
    QuizSeed {
        game_id: "quiz_thai_food",
        category: "ครอบครัว",
        question: "'ข้าวซอย' อาหารเส้นน้ำแกงกะทิหอมเครื่องเทศพร้อมหมี่กรอบ เป็นอาหารพื้นเมืองเด่นของภาคใด?",
        options: ["ภาคใต้", "ภาคเหนือ", "ภาคตะวันออก", "ภาคอีสาน"],
        correct_index: 1,
        explanation: "ข้าวซอยเป็นเมนูซิกเนเจอร์ของภาคเหนือ เสิร์ฟคู่ผักกาดดอง หอมแดง และมะนาว",
    },
    // #2 quiz_90s_thai
    QuizSeed {
        game_id: "quiz_90s_thai",
        category: "เพื่อน",
        question: "ในยุค 90 เวลาเทปคาสเซ็ตยืดหรืออยากกรอเทปแบบประหยัดถ่าน เด็กยุคนั้นมักใช้อะไรช่วยหมุนม้วนเทป?",
        options: ["ไม้บรรทัดเหล็ก", "ดินสอหรือปากกาหกเหลี่ยม", "ยางลบดินสอ", "คลิปหนีบกระดาษ"],
        correct_index: 1,
        explanation: "เสียบดินสอหรือปากกาเข้าเฟืองม้วนเทปแล้วควงหมุนกรอ เป็นสกิลระดับตำนานของเด็กยุค 90!",
    },
    QuizSeed {
        game_id: "quiz_90s_thai",
        category: "เพื่อน",
        question: "เกมกดสัตว์เลี้ยงดิจิทัลพกพาที่เด็กยุค 90 ต้องคอยป้อนข้าวและเก็บอึให้ตลอดวันคืออะไร?",
        options: ["รูบิค", "ทามาก็อตจิ", "ลูกข่างไม้", "หมากเก็บ"],
        correct_index: 1,
        explanation: "ทามาก็อตจิ (Tamagotchi) คือสัตว์เลี้ยงดิจิทัลยอดฮิตที่ทุกคนต้องคอยดูแลไม่ให้ป่วย",
    },
    // #3 quiz_thai_proverbs
    QuizSeed {
        game_id: "quiz_thai_proverbs",
        category: "ความรู้",
        question: "สำนวน 'เข็นครกขึ้นภูเขา' หมายถึงการกระทำในลักษณะใด?",
        options: [
            "ทำงานที่ยากลำบากและต้องใช้ความพยายามสูงมาก",
            "รีบฉวยโอกาสดีๆ ที่ผ่านเข้ามา",
            "ทำเรื่องเล็กให้กลายเป็นเรื่องใหญ่โต",
            "ช่วยกันทำงานจนสำเร็จอย่างรวดเร็ว",
        ],
        correct_index: 0,
        explanation: "เข็นครกขึ้นภูเขา เปรียบถึงงานที่ยากเย็นแสนเข็ญ ต้องใช้แรงกายแรงใจอย่างหนัก",
    },
    QuizSeed {
        game_id: "quiz_thai_proverbs",
        category: "ความรู้",
        question: "หากมีโอกาสดีเข้ามาและเพื่อนเตือนว่า 'น้ำขึ้นให้รีบตัก' เพื่อนกำลังแนะนำอะไร?",
        options: [
            "ให้รีบเก็บข้าวของหนีน้ำท่วม",
            "ให้รีบคว้าโอกาสดีๆ ในช่วงเวลาที่เหมาะสม",
            "ให้ค่อยๆ รอเวลาอย่าเพิ่งตัดสินใจ",
            "ให้ประหยัดน้ำในฤดูแล้ง",
        ],
        correct_index: 1,
        explanation: "น้ำขึ้นให้รีบตัก หมายถึงเมื่อโอกาสเอื้ออำนวยควรรีบลงมือทำก่อนโอกาสนั้นผ่านไป",
    },
    // #4 quiz_77_provinces
    QuizSeed {
        game_id: "quiz_77_provinces",
        category: "ครอบครัว",
        question: "จังหวัดที่มีพื้นที่ขนาดใหญ่ที่สุดในประเทศไทยคือจังหวัดใด?",
        options: ["เชียงใหม่", "นครราชสีมา", "กาญจนบุรี", "ตาก"],
        correct_index: 1,
        explanation: "นครราชสีมา (โคราช) เป็นจังหวัดที่มีพื้นที่ใหญ่ที่สุดในไทย รองลงมาคือเชียงใหม่และกาญจนบุรี",
    },
    QuizSeed {
        game_id: "quiz_77_provinces",
        category: "ครอบครัว",
        question: "จังหวัดที่ตั้งอยู่เหนือสุดของประเทศไทยคือจังหวัดใด?",
        options: ["เชียงใหม่", "แม่ฮ่องสอน", "เชียงราย", "น่าน"],
        correct_index: 2,
        explanation: "อำเภอแม่สาย จังหวัดเชียงราย เป็นจุดที่อยู่เหนือสุดในประเทศไทย",
    },
    // #5 quiz_teen_slang
    QuizSeed {
        game_id: "quiz_teen_slang",
        category: "เพื่อน",
        question: "เมื่อเพื่อนพิมพ์ชมชุดเราว่า 'จึ้งมาก!' ในภาษาแชทยุคใหม่หมายความว่าอะไร?",
        options: ["ดูง่วงนอนมาก", "สวยโดดเด่นสะดุดตามาก", "ราคาแพงเกินไป", "แต่งตัวช้ามาก"],
        correct_index: 1,
        explanation: "'จึ้ง' ใช้ชมอะไรที่สวย ปัง โดดเด่น หรือน่าประทับใจสุดๆ จนต้องมองซ้ำ",
    },
    QuizSeed {
        game_id: "quiz_teen_slang",
        category: "เพื่อน",
        question: "คำว่า 'ตึง' ในวงการเกมหรือแชทวัยรุ่น เช่น 'พี่คนนี้เล่นตึงมาก' หมายถึงอะไร?",
        options: ["เก่งมาก โหดมาก เล่นเอาจริง", "หน้าตึงไม่ยอมยิ้ม", "สัญญาณอินเทอร์เน็ตช้า", "เพิ่งหัดเล่นครั้งแรก"],
        correct_index: 0,
        explanation: "'ตึง' ใช้ชมคนที่ฝีมือจัดจ้าน เล่นเก่งมาก หรือสถานการณ์ที่เข้มข้นสุดๆ",
    },
    // #6 quiz_office_life
    QuizSeed {
        game_id: "quiz_office_life",
        category: "ทำงาน",
        question: "ในอีเมลหรือแชทงาน คำย่อ 'FYI' ย่อมาจากอะไรและใช้เพื่อจุดประสงค์ใด?",
        options: [
            "For Your Information — แจ้งเพื่อทราบ",
            "Finish Your Idea — รีบส่งไอเดียด่วน",
            "Fix Your Issue — แก้บั๊กเดี๋ยวนี้",
            "Find Your Invoice — ตามใบแจ้งหนี้",
        ],
        correct_index: 0,
        explanation: "FYI ย่อมาจาก For Your Information ใช้ส่งข้อมูลเพื่อให้ผู้รับทราบประกอบการทำงาน",
    },
    QuizSeed {
        game_id: "quiz_office_life",
        category: "ทำงาน",
        question: "เวลาแชร์ไฟล์เอกสารให้เพื่อนร่วมงานโดยอยากให้ทุกคนเห็นการแก้ไขล่าสุดพร้อมกัน ควรทำอย่างไร?",
        options: [
            "ส่งไฟล์ชื่อ Final_v9_จริงจัง.docx ซ้ำทุกชั่วโมง",
            "ใช้ลิงก์เอกสารออนไลน์กลางที่อัปเดตเวอร์ชันเดียว",
            "พิมพ์กระดาษแล้วถ่ายรูปส่งทีละหน้า",
            "เปลี่ยนชื่อไฟล์เป็นตัวเลขสุ่มทุกครั้ง",
        ],
        correct_index: 1,
        explanation: "การแชร์เอกสารกลางเวอร์ชันเดียวช่วยลดความสับสนเรื่องไฟล์ซ้ำและทำงานร่วมกันได้ไวขึ้น",
    },
    // #7 quiz_personal_finance
    QuizSeed {
        game_id: "quiz_personal_finance",
        category: "ทำงาน",
        question: "หลักวางแผนการเงินพื้นฐานแนะนำให้มี 'เงินสำรองฉุกเฉิน' เก็บไว้ประมาณกี่เท่าของค่าใช้จ่ายต่อเดือน?",
        options: ["ครึ่งเดือน", "1 เดือน", "3 ถึง 6 เดือน", "24 เดือนขึ้นไปเท่านั้น"],
        correct_index: 2,
        explanation: "เงินสำรองฉุกเฉิน 3-6 เท่าของค่าใช้จ่ายจำเป็นต่อเดือน ช่วยรองรับเหตุไม่คาดฝันได้อุ่นใจ",
    },
    QuizSeed {
        game_id: "quiz_personal_finance",
        category: "ทำงาน",
        question: "'ดอกเบี้ยทบต้น' มีความหมายตรงกับข้อใดมากที่สุด?",
        options: [
            "ดอกเบี้ยที่คิดเฉพาะจากเงินต้นครั้งแรกเท่านั้น",
            "ดอกเบี้ยที่นำดอกเบี้ยเดิมมารวมกับเงินต้นแล้วคิดดอกเบี้ยต่อในงวดถัดไป",
            "ค่าธรรมเนียมการถอนเงินจากตู้เอทีเอ็ม",
            "ส่วนลดเมื่อชำระเงินด้วยเงินสด",
        ],
        correct_index: 1,
        explanation: "ดอกเบี้ยทบต้นทำให้เงินออมหรือการลงทุนเติบโตแบบทวีคูณเมื่อปล่อยให้เวลาทำงานร่วมด้วย",
    },
    // #8 quiz_animal_world
    QuizSeed {
        game_id: "quiz_animal_world",
        category: "ความรู้",
        question: "สัตว์บกชนิดใดที่สามารถวิ่งได้เร็วที่สุดในโลก?",
        options: ["สิงโต", "เสือชีตาห์", "ม้าแข่ง", "จิงโจ้แดง"],
        correct_index: 1,
        explanation: "เสือชีตาห์สามารถเร่งความเร็วช่วงสั้นได้สูงกว่า 100 กิโลเมตรต่อชั่วโมง ครองแชมป์สัตว์บกที่เร็วที่สุด",
    },
    QuizSeed {
        game_id: "quiz_animal_world",
        category: "ความรู้",
        question: "หมึกยักษ์ (Octopus) มีหัวใจทั้งหมดกี่ดวง?",
        options: ["1 ดวง", "2 ดวง", "3 ดวง", "8 ดวง"],
        correct_index: 2,
        explanation: "หมึกยักษ์มีหัวใจ 3 ดวง — 2 ดวงสูบฉีดเลือดไปที่เหงือก และอีก 1 ดวงสูบฉีดไปเลี้ยงร่างกาย",
    },
    // #9 quiz_thai_drama_cinema
    QuizSeed {
        game_id: "quiz_thai_drama_cinema",
        category: "เพื่อน",
        question: "ในกองถ่ายภาพยนตร์หรือละคร อุปกรณ์ไม้กระดานที่มีเสียง 'แชะ!' ก่อนเริ่มถ่ายแต่ละฉากเรียกว่าอะไร?",
        options: ["สเลท (Clapperboard)", "สคริปต์บอร์ด", "รีเฟล็กเตอร์", "ดอลลี่"],
        correct_index: 0,
        explanation: "สเลท (Clapperboard) ใช้บอกเลขฉาก/เทก และใช้เสียงตบเพื่อซิงก์ภาพกับเสียงในขั้นตอนตัดต่อ",
    },
    QuizSeed {
        game_id: "quiz_thai_drama_cinema",
        category: "เพื่อน",
        question: "คำว่า 'Plot Twist' ในวงการหนังและซีรีส์หมายถึงอะไร?",
        options: [
            "เพลงประกอบตอนจบเรื่อง",
            "การหักมุมของเนื้อเรื่องอย่างคาดไม่ถึง",
            "การถ่ายทำซ้ำหลายรอบ",
            "ฉากเปิดตัวพระเอกนางเอก",
        ],
        correct_index: 1,
        explanation: "Plot Twist คือจุดหักมุมที่เปลี่ยนทิศทางความเข้าใจของคนดูอย่างเซอร์ไพรส์",
    },
    // #10 quiz_everyday_science
    QuizSeed {
        game_id: "quiz_everyday_science",
        category: "ความรู้",
        question: "แก๊สที่มีสัดส่วนมากที่สุดในอากาศรอบตัวเราบนโลกคือแก๊สชนิดใด?",
        options: ["ออกซิเจน", "คาร์บอนไดออกไซด์", "ไนโตรเจน", "ไฮโดรเจน"],
        correct_index: 2,
        explanation: "อากาศบนโลกประกอบด้วยไนโตรเจนประมาณ 78% และออกซิเจนประมาณ 21%",
    },
    QuizSeed {
        game_id: "quiz_everyday_science",
        category: "ความรู้",
        question: "เมื่อเกิดฟ้าแลบและฟ้าร้องพร้อมกัน ทำไมเราจึงเห็นแสงฟ้าแลบก่อนได้ยินเสียงฟ้าร้องเสมอ?",
        options: [
            "แสงเดินทางเร็วกว่าเสียงมาก",
            "เสียงต้องรอให้เมฆแยกตัวก่อน",
            "ตาอยู่สูงกว่าหู",
            "ฟ้าแลบเกิดก่อนฟ้าร้อง 10 วินาทีเสมอ",
        ],
        correct_index: 0,
        explanation: "แสงเดินทางเร็วราว 300,000 กม./วินาที ส่วนเสียงในอากาศราว 343 ม./วินาที เราจึงเห็นแสงก่อนมาก",
    },
    // #11 quiz_practical_english
    QuizSeed {
        game_id: "quiz_practical_english",
        category: "ทำงาน",
        question: "สำนวนภาษาอังกฤษ 'Break a leg!' เมื่อพูดก่อนเพื่อนขึ้นเวทีพรีเซนต์ หมายความว่าอย่างไร?",
        options: [
            "ระวังเดินสะดุดขาตัวเอง",
            "ขอให้โชคดีและทำได้ยอดเยี่ยม!",
            "ขอพักเบรกก่อนเริ่มงาน",
            "ยกเลิกการแสดงเดี๋ยวนี้",
        ],
        correct_index: 1,
        explanation: "'Break a leg!' เป็นสำนวนอวยพรให้โชคดีที่นิยมใช้มากก่อนการแสดงหรือการพรีเซนต์สำคัญ",
    },
    QuizSeed {
        game_id: "quiz_practical_english",
        category: "ทำงาน",
        question: "ประโยค 'Let's call it a day' ในที่ทำงานมีความหมายว่าอะไร?",
        options: [
            "โทรหาลูกค้าภายในวันนี้",
            "พอแค่นี้ก่อน เลิกงานวันนี้กันเถอะ",
            "นัดประชุมเพิ่มพรุ่งนี้เช้า",
            "ตั้งชื่อโปรเจกต์ใหม่วันนี้",
        ],
        correct_index: 1,
        explanation: "'Call it a day' แปลว่าจบการทำงานสำหรับวันนี้แล้ว พักผ่อนได้!",
    },
    // #12 quiz_thai_history
    QuizSeed {
        game_id: "quiz_thai_history",
        category: "ความรู้",
        question: "สมัยกรุงธนบุรีเป็นราชธานีของไทย มีพระมหากษัตริย์ปกครองกี่พระองค์?",
        options: ["1 พระองค์", "3 พระองค์", "5 พระองค์", "9 พระองค์"],
        correct_index: 0,
        explanation: "กรุงธนบุรีมีพระมหากษัตริย์เพียง 1 พระองค์ คือ สมเด็จพระเจ้าตากสินมหาราช (พ.ศ. 2310-2325)",
    },
    QuizSeed {
        game_id: "quiz_thai_history",
        category: "ความรู้",
        question: "ลายสือไทย (อักษรไทยยุคแรก) ประดิษฐ์ขึ้นในสมัยราชธานีใด?",
        options: ["กรุงศรีอยุธยา", "กรุงสุโขทัย", "กรุงธนบุรี", "กรุงรัตนโกสินทร์"],
        correct_index: 1,
        explanation: "พ่อขุนรามคำแหงมหาราชทรงประดิษฐ์ลายสือไทยขึ้นในสมัยกรุงสุโขทัย เมื่อ พ.ศ. 1826",
    },
    // #13 quiz_thai_spelling
    QuizSeed {
        game_id: "quiz_thai_spelling",
        category: "ความรู้",
        question: "ข้อใดสะกดคำว่า 'อนุญาต' ได้ถูกต้องตามพจนานุกรมราชบัณฑิตยสถาน?",
        options: ["อนุญาติ", "อนุญาต", "อนุยาด", "อนุญาตุ"],
        correct_index: 1,
        explanation: "'อนุญาต' ไม่มีสระอิ (ต่างจากคำว่า 'ญาติ' ที่มีสระอิ)",
    },
    QuizSeed {
        game_id: "quiz_thai_spelling",
        category: "ความรู้",
        question: "ข้อใดสะกดคำว่า 'สังเกต' ได้ถูกต้องตามหลักภาษาไทย?",
        options: ["สังเกตุ", "สังเกต", "สังเกติ", "สังเกตร์"],
        correct_index: 1,
        explanation: "'สังเกต' สะกดด้วย ต เต่า ไม่มีสระอุ (คำที่มีสระอุคือ 'เหตุ')",
    },
    // #14 quiz_speed_math
    QuizSeed {
        game_id: "quiz_speed_math",
        category: "ความรู้",
        question: "เสื้อราคาป้าย 800 บาท จัดโปรโมชันลด 25% ต้องจ่ายเงินจริงกี่บาท?",
        options: ["550 บาท", "600 บาท", "625 บาท", "650 บาท"],
        correct_index: 1,
        explanation: "ลด 25% ของ 800 คือ 200 บาท ดังนั้นราคาจ่ายจริงคือ 800 - 200 = 600 บาท",
    },
    QuizSeed {
        game_id: "quiz_speed_math",
        category: "ความรู้",
        question: "ผลลัพธ์ของ (15 × 4) + (36 ÷ 6) เท่ากับข้อใด?",
        options: ["62", "64", "66", "72"],
        correct_index: 2,
        explanation: "15 × 4 = 60 และ 36 ÷ 6 = 6 นำมารวมกันได้ 66",
    },
    // #15 quiz_brain_teaser
    QuizSeed {
        game_id: "quiz_brain_teaser",
        category: "ทายใจ/ฮา",
        question: "ถ้าคุณวิ่งแข่งแล้วแซงคนที่อยู่อันดับ 2 ได้สำเร็จ ตอนนี้คุณอยู่อันดับที่เท่าไร?",
        options: ["อันดับ 1", "อันดับ 2", "อันดับ 3", "เสมอกัน"],
        correct_index: 1,
        explanation: "เมื่อคุณแซงคนที่อยู่อันดับ 2 คุณก็ขึ้นมาแทนที่อันดับ 2 นั่นเอง (อันดับ 1 ยังนำอยู่!)",
    },
    QuizSeed {
        game_id: "quiz_brain_teaser",
        category: "ทายใจ/ฮา",
        question: "เดือนใดในปฏิทินสากลที่มีวันที่ 28?",
        options: ["เฉพาะเดือนกุมภาพันธ์", "6 เดือนต่อปี", "11 เดือนต่อปี", "ครบทั้ง 12 เดือน"],
        correct_index: 3,
        explanation: "ทุกเดือนมีอย่างน้อย 28 วัน ดังนั้นครบทั้ง 12 เดือนเลยที่มีวันที่ 28!",
    },
    // #16 quiz_fruits_herbs
    QuizSeed {
        game_id: "quiz_fruits_herbs",
        category: "ครอบครัว",
        question: "ผลไม้ไทยชนิดใดที่ได้รับฉายาว่า 'ราชินีแห่งผลไม้' (Queen of Fruits)?",
        options: ["ทุเรียน", "มังคุด", "เงาะ", "ลำไย"],
        correct_index: 1,
        explanation: "มังคุดคือ 'ราชินีแห่งผลไม้' ส่วนทุเรียนคือ 'ราชาแห่งผลไม้' กินคู่กันช่วยปรับสมดุลร้อน-เย็น",
    },
    QuizSeed {
        game_id: "quiz_fruits_herbs",
        category: "ครอบครัว",
        question: "สมุนไพรไทยชนิดใดที่ให้สีน้ำเงินอมม่วงธรรมชาติ และเปลี่ยนเป็นสีม่วงแดงเมื่อบีบมะนาวลงไป?",
        options: ["ใบเตย", "ดอกอัญชัน", "กระเจี๊ยบแดง", "ขมิ้นชัน"],
        correct_index: 1,
        explanation: "ดอกอัญชันมีสารแอนโทไซยานินซึ่งเปลี่ยนสีตามความเป็นกรด-ด่าง พอเจอน้ำมะนาวจึงกลายเป็นสีม่วงสวย",
    },
    // #17 quiz_sports_mania
    QuizSeed {
        game_id: "quiz_sports_mania",
        category: "เพื่อน",
        question: "ในกีฬาแบดมินตันระบบแรลลี่พอยต์มาตรฐาน เกมหนึ่งต้องทำคะแนนให้ถึงกี่แต้มจึงชนะ (กรณีไม่ดิวซ์)?",
        options: ["11 แต้ม", "15 แต้ม", "21 แต้ม", "25 แต้ม"],
        correct_index: 2,
        explanation: "แบดมินตันสากลเล่นเกมละ 21 แต้ม ชนะ 2 ใน 3 เกม (หาก 20-20 ต้องชนะห่าง 2 แต้ม สูงสุดที่ 30)",
    },
    QuizSeed {
        game_id: "quiz_sports_mania",
        category: "เพื่อน",
        question: "ในกีฬาวอลเลย์บอลในร่ม ทีมหนึ่งลงสนามพร้อมกันได้กี่คน?",
        options: ["5 คน", "6 คน", "7 คน", "9 คน"],
        correct_index: 1,
        explanation: "วอลเลย์บอลในร่มมีผู้เล่นฝั่งละ 6 คน แบ่งเป็นแดนหน้า 3 คน และแดนหลัง 3 คน",
    },
    // #18 quiz_thai_music
    QuizSeed {
        game_id: "quiz_thai_music",
        category: "เพื่อน",
        question: "เครื่องดนตรีไทยชนิดใดจัดอยู่ในประเภท 'เครื่องสี'?",
        options: ["จะเข้", "ซอด้วง", "ขลุ่ยเพียงออ", "ระนาดเอก"],
        correct_index: 1,
        explanation: "ซอด้วงและซออู้เป็นเครื่องสีที่ใช้คันชักสีสายให้เกิดเสียง ส่วนจะเข้เป็นเครื่องดีด",
    },
    QuizSeed {
        game_id: "quiz_thai_music",
        category: "เพื่อน",
        question: "กีตาร์โปร่งมาตรฐานทั่วไปมีสายทั้งหมดกี่สาย?",
        options: ["4 สาย", "5 สาย", "6 สาย", "8 สาย"],
        correct_index: 2,
        explanation: "กีตาร์มาตรฐานมี 6 สาย ตั้งเสียงพื้นฐานเป็น E-A-D-G-B-E",
    },
    // #19 quiz_tech_ai
    QuizSeed {
        game_id: "quiz_tech_ai",
        category: "ทำงาน",
        question: "การเปิดใช้งาน '2FA' (Two-Factor Authentication) บนบัญชีออนไลน์มีประโยชน์หลักอย่างไร?",
        options: [
            "ทำให้เน็ตมือถือเร็วขึ้น 2 เท่า",
            "เพิ่มชั้นความปลอดภัยต้องยืนยันตัวตนอีกขั้นแม้อีกฝ่ายรู้รหัสผ่าน",
            "เพิ่มพื้นที่เก็บข้อมูลฟรี 2 เท่า",
            "ทำให้แบตเตอรี่โทรศัพท์อึดขึ้น",
        ],
        correct_index: 1,
        explanation: "2FA ช่วยป้องกันบัญชีถูกแฮกได้ดีมาก เพราะต้องใช้รหัสชั้นที่ 2 เช่น OTP หรือแอปยืนยันตัวตนร่วมด้วย",
    },
    QuizSeed {
        game_id: "quiz_tech_ai",
        category: "ทำงาน",
        question: "คำว่า 'Prompt' เมื่อใช้งานผู้ช่วยปัญญาประดิษฐ์ (AI) หมายถึงอะไร?",
        options: [
            "สายชาร์จสำหรับเซิร์ฟเวอร์",
            "คำสั่งหรือข้อความที่เราป้อนให้ AI ช่วยคิดหรือสร้างคำตอบ",
            "หน่วยความจำการ์ดจอ",
            "ชื่อไวรัสคอมพิวเตอร์",
        ],
        correct_index: 1,
        explanation: "Prompt คือโจทย์หรือคำสั่งที่เราสื่อสารกับ AI ยิ่งระบุบริบทชัด AI ยิ่งตอบได้ตรงใจ",
    },
    // #20 quiz_world_travel
    QuizSeed {
        game_id: "quiz_world_travel",
        category: "ความรู้",
        question: "เมืองหลวงของประเทศออสเตรเลียคือเมืองใด?",
        options: ["ซิดนีย์", "เมลเบิร์น", "แคนเบอร์รา", "บริสเบน"],
        correct_index: 2,
        explanation: "หลายคนมักจำสลับกับซิดนีย์ แต่เมืองหลวงอย่างเป็นทางการของออสเตรเลียคือ 'แคนเบอร์รา'",
    },
    QuizSeed {
        game_id: "quiz_world_travel",
        category: "ความรู้",
        question: "สกุลเงินที่ใช้กันอย่างเป็นทางการในประเทศญี่ปุ่นคือสกุลเงินใด?",
        options: ["วอน", "เยน", "หยวน", "ดอลลาร์"],
        correct_index: 1,
        explanation: "ญี่ปุ่นใช้สกุลเงิน 'เยน' (JPY) ส่วนวอนเป็นของเกาหลีใต้ และหยวนเป็นของจีน",
    },
    // #21 quiz_traffic_driving
    QuizSeed {
        game_id: "quiz_traffic_driving",
        category: "ครอบครัว",
        question: "เส้นทึบสีเหลืองคู่กลางถนนมีความหมายจราจรว่าอย่างไร?",
        options: [
            "สามารถแซงได้ตลอดเวลา",
            "ห้ามรถทั้งสองทิศทางขับข้ามหรือแซงเข้าไปในช่องทางสวน",
            "เป็นช่องจอดรถชั่วคราว",
            "ให้ใช้ความเร็วเพิ่มขึ้นทันที",
        ],
        correct_index: 1,
        explanation: "เส้นทึบสีเหลืองคู่ห้ามขับล้ำหรือแซงเด็ดขาด เพราะมักเป็นช่วงโค้ง เนิน หรือจุดอับสายตา",
    },
    QuizSeed {
        game_id: "quiz_traffic_driving",
        category: "ครอบครัว",
        question: "เมื่อเห็นสัญญาณ 'ไฟเหลืองกะพริบ' ที่ทางแยก ผู้ขับขี่ควรปฏิบัติอย่างไร?",
        options: [
            "เหยียบคันเร่งผ่านให้เร็วที่สุด",
            "หยุดรถรอจนกว่าจะเปลี่ยนเป็นไฟเขียว",
            "ชะลอความเร็ว เพิ่มความระมัดระวัง และมองรถด้านอื่นก่อนผ่าน",
            "เปิดไฟสูงค้างไว้แล้วขับผ่าน",
        ],
        correct_index: 2,
        explanation: "ไฟเหลืองกะพริบเตือนให้ลดความเร็วและระมัดระวังเป็นพิเศษ ส่วนไฟแดงกะพริบให้หยุดก่อนแล้วค่อยไปเมื่อปลอดภัย",
    },
    // #22 quiz_health_nutrition
    QuizSeed {
        game_id: "quiz_health_nutrition",
        category: "ครอบครัว",
        question: "สารอาหารกลุ่มใดมีบทบาทหลักในการซ่อมแซมส่วนที่สึกหรอและสร้างกล้ามเนื้อ?",
        options: ["โปรตีน", "น้ำตาลทราย", "เกลือโซเดียม", "ใยอาหาร"],
        correct_index: 0,
        explanation: "โปรตีนจากไข่ ปลา เนื้อสัตว์ไม่ติดมัน ถั่ว และเต้าหู้ ช่วยสร้างและซ่อมแซมเนื้อเยื่อของร่างกาย",
    },
    QuizSeed {
        game_id: "quiz_health_nutrition",
        category: "ครอบครัว",
        question: "พฤติกรรมใดช่วยให้การนอนหลับตอนกลางคืนมีคุณภาพดีขึ้นมากที่สุด?",
        options: [
            "ดื่มกาแฟเข้มๆ ก่อนนอน 30 นาที",
            "เข้านอนและตื่นเวลาใกล้เคียงกันสม่ำเสมอ พร้อมลดแสงจอก่อนนอน",
            "เล่นมือถือเปิดแสงจ้าในห้องมืดจนหลับคาจอ",
            "กินมื้อดึกอิ่มจัดแล้วนอนทันที",
        ],
        correct_index: 1,
        explanation: "การรักษาเวลาหลับ-ตื่นให้สม่ำเสมอและลดแสงสีฟ้าก่อนนอนช่วยให้นาฬิกาชีวภาพทำงานได้ดี",
    },
    // #23 quiz_coffee_cafe
    QuizSeed {
        game_id: "quiz_coffee_cafe",
        category: "เพื่อน",
        question: "เมนูกาแฟ 'อเมริกาโน (Americano)' มีส่วนผสมหลักคืออะไร?",
        options: [
            "เอสเปรสโซผสมน้ำร้อนหรือน้ำเย็น",
            "เอสเปรสโซผสมนมข้นหวานและครีมเทียม",
            "เอสเปรสโซผสมซอสช็อกโกแลตและนมสด",
            "กาแฟผงผสมน้ำส้มคั้นเท่านั้น",
        ],
        correct_index: 0,
        explanation: "อเมริกาโนคือช็อตเอสเปรสโซที่เติมน้ำลงไปให้ดื่มง่ายขึ้น คงกลิ่นหอมกาแฟโดยไม่ใส่นม",
    },
    QuizSeed {
        game_id: "quiz_coffee_cafe",
        category: "เพื่อน",
        question: "ระหว่าง 'ลาเต้ (Latte)' กับ 'มอคค่า (Mocha)' อะไรคือจุดต่างที่เห็นชัดที่สุด?",
        options: [
            "มอคค่ามีการผสมช็อกโกแลตหรือโกโก้เพิ่มเข้าไป",
            "ลาเต้ไม่ใส่นมเลย",
            "มอคค่าใช้ใบชาแทนกาแฟ",
            "ลาเต้ต้องเสิร์ฟปั่นเท่านั้น",
        ],
        correct_index: 0,
        explanation: "มอคค่าคือกาแฟเอสเปรสโซผสมนมและช็อกโกแลต เหมาะกับคนชอบความหอมหวานละมุน",
    },
    // #24 quiz_thai_culture
    QuizSeed {
        game_id: "quiz_thai_culture",
        category: "ครอบครัว",
        question: "ลวดลายเส้นเกลียวคลื่นสีแดงดินเผาอันเป็นเอกลักษณ์ระดับมรดกโลกของไทย มาจากแหล่งโบราณคดีใด?",
        options: ["บ้านเชียง จังหวัดอุดรธานี", "เมืองโบราณอู่ทอง", "ปราสาทหินพิมาย", "เวียงกุมกาม"],
        correct_index: 0,
        explanation: "แหล่งโบราณคดีบ้านเชียง จ.อุดรธานี ขึ้นชื่อเรื่องภาชนะดินเผาลายเขียนสีแดงเกลียวคลื่นอันงดงาม",
    },
    QuizSeed {
        game_id: "quiz_thai_culture",
        category: "ครอบครัว",
        question: "ประเพณี 'ลอยกระทง' ของไทยจัดขึ้นในวันใดตามปฏิทินจันทรคติ?",
        options: [
            "วันขึ้น 15 ค่ำ เดือน 6",
            "วันขึ้น 15 ค่ำ เดือน 12",
            "วันแรม 15 ค่ำ เดือน 10",
            "วันขึ้น 1 ค่ำ เดือน 5",
        ],
        correct_index: 1,
        explanation: "วันลอยกระทงตรงกับวันเพ็ญขึ้น 15 ค่ำ เดือน 12 เป็นช่วงน้ำหลากและพระจันทร์เต็มดวงสวยงาม",
    },
    // #25 quiz_cute_pets
    QuizSeed {
        game_id: "quiz_cute_pets",
        category: "ครอบครัว",
        question: "อาหารชนิดใดต่อไปนี้ที่เป็นพิษและห้ามให้สุนัขกินเด็ดขาด?",
        options: ["ฟักทองนึ่งจืด", "ช็อกโกแลตและองุ่น", "อกไก่ต้มไม่ปรุงรส", "แคร์รอตหั่นชิ้นเล็ก"],
        correct_index: 1,
        explanation: "ช็อกโกแลตมีสารธีโอโบรมีน และองุ่น/ลูกเกดอาจทำอันตรายต่อไตสุนัข จึงห้ามให้กินเด็ดขาด",
    },
    QuizSeed {
        game_id: "quiz_cute_pets",
        category: "ครอบครัว",
        question: "เวลาแมวค่อยๆ กะพริบตาช้าๆ (Slow Blink) ใส่เจ้าของ มักสื่อถึงอารมณ์แบบใด?",
        options: [
            "กำลังโกรธจัดพร้อมตะปบ",
            "รู้สึกปลอดภัย ไว้ใจ และส่งความรักให้",
            "ปวดท้องอย่างรุนแรง",
            "อยากให้เปิดเพลงเสียงดังๆ",
        ],
        correct_index: 1,
        explanation: "การกะพริบตาช้าๆ คือ 'จูบของแมว' แปลว่าน้องรู้สึกสบายใจและไว้ใจคุณมากๆ",
    },
    // #26 quiz_home_hacks
    QuizSeed {
        game_id: "quiz_home_hacks",
        category: "ครอบครัว",
        question: "หากทำเสื้อผ้าสีขาวเปื้อนเลือดสด ควรใช้น้ำอุณหภูมิแบบใดล้างออกในขั้นตอนแรก?",
        options: ["น้ำเดือดจัด", "น้ำอุ่นจัด", "น้ำเย็น", "น้ำส้มสายชูต้มร้อน"],
        correct_index: 2,
        explanation: "น้ำเย็นช่วยไม่ให้โปรตีนในคราบจับตัวแน่นกับเส้นใยผ้า จึงล้างคราบออกได้ง่ายกว่าน้ำร้อนมาก",
    },
    QuizSeed {
        game_id: "quiz_home_hacks",
        category: "ครอบครัว",
        question: "ของใช้ในครัวชนิดใดที่นิยมวางเปิดฝาไว้ในตู้เย็นเพื่อช่วยดูดซับกลิ่นอับได้ดี?",
        options: ["เบกกิ้งโซดา (โซเดียมไบคาร์บอเนต)", "น้ำตาลทรายแดง", "แป้งมันสำปะหลัง", "น้ำมันพืช"],
        correct_index: 0,
        explanation: "เบกกิ้งโซดาช่วยดูดซับกลิ่นอาหารในตู้เย็นได้ดี ควรเปลี่ยนใหม่ทุก 1-3 เดือน",
    },
    // #27 quiz_space_stars
    QuizSeed {
        game_id: "quiz_space_stars",
        category: "ความรู้",
        question: "ดาวเคราะห์ดวงใดในระบบสุริยะที่อยู่ใกล้ดวงอาทิตย์มากที่สุด?",
        options: ["ดาวศุกร์", "ดาวพุธ", "ดาวอังคาร", "โลก"],
        correct_index: 1,
        explanation: "ดาวพุธ (Mercury) อยู่ใกล้ดวงอาทิตย์ที่สุด แต่ดาวศุกร์ร้อนกว่าเพราะชั้นบรรยากาศหนาเก็บความร้อน",
    },
    QuizSeed {
        game_id: "quiz_space_stars",
        category: "ความรู้",
        question: "ดาวเคราะห์ที่มีขนาดใหญ่ที่สุดในระบบสุริยะของเราคือดวงใด?",
        options: ["ดาวเสาร์", "ดาวพฤหัสบดี", "ดาวยูเรนัส", "ดาวเนปจูน"],
        correct_index: 1,
        explanation: "ดาวพฤหัสบดี (Jupiter) เป็นดาวเคราะห์แก๊สยักษ์ที่มีขนาดและมวลใหญ่ที่สุดในระบบสุริยะ",
    },
    // #28 quiz_asian_street_food
    QuizSeed {
        game_id: "quiz_asian_street_food",
        category: "เพื่อน",
        question: "'เฝอ (Pho)' ก๋วยเตี๋ยวน้ำซุปหอมเครื่องเทศเสิร์ฟพร้อมผักสด เป็นอาหารขึ้นชื่อของประเทศใด?",
        options: ["ญี่ปุ่น", "เกาหลีใต้", "เวียดนาม", "อินโดนีเซีย"],
        correct_index: 2,
        explanation: "เฝอคือเมนูประจำชาติยอดฮิตของเวียดนาม จุดเด่นอยู่ที่น้ำซุปเคี่ยวหอมและเส้นก๋วยเตี๋ยวนุ่มๆ",
    },
    QuizSeed {
        game_id: "quiz_asian_street_food",
        category: "เพื่อน",
        question: "ขนมแป้งกลมไส้ปลาหมึกยักษ์ราดซอสและโรยปลาแห้ง 'ทาโกะยากิ' มีต้นกำเนิดจากเมืองใดของญี่ปุ่น?",
        options: ["โอซาก้า", "ซัปโปโร", "โอกินาวา", "นางาซากิ"],
        correct_index: 0,
        explanation: "โอซาก้าขึ้นชื่อว่าเป็นครัวของญี่ปุ่นและเป็นบ้านเกิดของทาโกะยากิยอดนิยม",
    },
    // #29 quiz_social_etiquette
    QuizSeed {
        game_id: "quiz_social_etiquette",
        category: "ทำงาน",
        question: "เมื่อต้องส่งข้อความเรื่องงานให้เพื่อนร่วมงานนอกเวลางานดึกๆ แต่ไม่เร่งด่วน วิธีที่มีมารยาทที่สุดคือข้อใด?",
        options: [
            "โทรจี้ 3 สายติดจนกว่าจะรับ",
            "ส่งแบบข้อความเงียบหรือรอส่งตอนเช้า พร้อมระบุว่าไม่ด่วน",
            "พิมพ์ว่า 'มีเรื่องด่วนมาก' ทั้งที่ไม่ด่วน",
            "แท็กทุกคนในกลุ่มตอนตี 2",
        ],
        correct_index: 1,
        explanation: "การเคารพเวลาพักผ่อนหรือใช้โหมดข้อความเงียบช่วยให้ทีมทำงานร่วมกันอย่างสบายใจและมืออาชีพ",
    },
    QuizSeed {
        game_id: "quiz_social_etiquette",
        category: "ทำงาน",
        question: "บนโต๊ะอาหารร่วมกันในวงไทย การใช้ 'ช้อนกลาง' มีจุดประสงค์หลักเพื่ออะไร?",
        options: [
            "ตักอาหารจากจานรวมมาใส่จานตัวเองอย่างถูกสุขอนามัย",
            "เอาไว้เคาะจังหวะเรียกพนักงาน",
            "ใช้แทนส้อมเวลาตักข้าวเข้าปาก",
            "วางประดับโต๊ะเฉยๆ ไม่ต้องใช้",
        ],
        correct_index: 0,
        explanation: "ช้อนกลางช่วยป้องกันการแพร่เชื้อโรคและเป็นมารยาทที่ดีในการรับประทานอาหารร่วมกัน",
    },
    // #30 quiz_famous_years
    QuizSeed {
        game_id: "quiz_famous_years",
        category: "ความรู้",
        question: "มนุษย์ลงเหยียบพื้นผิวดวงจันทร์ครั้งแรกในภารกิจอะพอลโล 11 เกิดขึ้นในปี ค.ศ. ใด?",
        options: ["ค.ศ. 1959", "ค.ศ. 1969", "ค.ศ. 1979", "ค.ศ. 1989"],
        correct_index: 1,
        explanation: "นีล อาร์มสตรอง ก้าวลงบนดวงจันทร์เมื่อวันที่ 20 กรกฎาคม ค.ศ. 1969",
    },
    QuizSeed {
        game_id: "quiz_famous_years",
        category: "ความรู้",
        question: "รถไฟฟ้า BTS สายแรกในกรุงเทพมหานครเปิดให้บริการประชาชนอย่างเป็นทางการในเดือนธันวาคม พ.ศ. ใด?",
        options: ["พ.ศ. 2535", "พ.ศ. 2542", "พ.ศ. 2550", "พ.ศ. 2555"],
        correct_index: 1,
        explanation: "รถไฟฟ้า BTS เปิดให้บริการวันแรกเมื่อวันที่ 5 ธันวาคม พ.ศ. 2542 (ค.ศ. 1999)",
    },
];

pub fn fallback_quiz_pack(
    game: &GameCatalogItem,
    count: usize,
    seed: u64,
) -> Vec<FallbackQuizQuestion> {
    let mut tier1 = Vec::new();
    let mut tier2 = Vec::new();
    let mut tier3 = Vec::new();

    for (idx, q) in QUIZ_BANK.iter().enumerate() {
        if q.game_id == game.id {
            tier1.push(idx);
        } else if q.category == game.category {
            tier2.push(idx);
        } else {
            tier3.push(idx);
        }
    }

    let picked = select_prioritized_indices(
        tier1,
        tier2,
        tier3,
        count,
        seed ^ fnv1a_64(game.id),
    );

    picked
        .into_iter()
        .map(|idx| {
            let item = &QUIZ_BANK[idx];
            FallbackQuizQuestion {
                question: item.question.to_string(),
                options: item.options.iter().map(|s| (*s).to_string()).collect(),
                correct_index: item.correct_index,
                explanation: item.explanation.to_string(),
            }
        })
        .collect()
}

// =============================================================================
// Curated Thai Fallback Bank 2: UNDERCOVER (45 distinct pairs — 3 per game)
// =============================================================================

struct UndercoverSeed {
    game_id: &'static str,
    label: &'static str,
    word_a: &'static str,
    word_b: &'static str,
}

const UNDERCOVER_BANK: &[UndercoverSeed] = &[
    // #31 uc_street_food
    UndercoverSeed { game_id: "uc_street_food", label: "สตรีทฟู้ดไทย", word_a: "ผัดไทย", word_b: "ผัดซีอิ๊ว" },
    UndercoverSeed { game_id: "uc_street_food", label: "สตรีทฟู้ดไทย", word_a: "หมูปิ้ง", word_b: "ไก่ย่าง" },
    UndercoverSeed { game_id: "uc_street_food", label: "สตรีทฟู้ดไทย", word_a: "ส้มตำไทย", word_b: "ยำวุ้นเส้น" },
    // #32 uc_thai_fruits
    UndercoverSeed { game_id: "uc_thai_fruits", label: "ผลไม้ไทย", word_a: "เงาะ", word_b: "ลิ้นจี่" },
    UndercoverSeed { game_id: "uc_thai_fruits", label: "ผลไม้ไทย", word_a: "ทุเรียน", word_b: "ขนุน" },
    UndercoverSeed { game_id: "uc_thai_fruits", label: "ผลไม้ไทย", word_a: "มะม่วง", word_b: "มะละกอ" },
    // #33 uc_thai_travel
    UndercoverSeed { game_id: "uc_thai_travel", label: "ที่เที่ยวไทย", word_a: "ภูเก็ต", word_b: "กระบี่" },
    UndercoverSeed { game_id: "uc_thai_travel", label: "ที่เที่ยวไทย", word_a: "เชียงใหม่", word_b: "เชียงราย" },
    UndercoverSeed { game_id: "uc_thai_travel", label: "ที่เที่ยวไทย", word_a: "หัวหิน", word_b: "พัทยา" },
    // #34 uc_professions
    UndercoverSeed { game_id: "uc_professions", label: "อาชีพ", word_a: "หมอ", word_b: "พยาบาล" },
    UndercoverSeed { game_id: "uc_professions", label: "อาชีพ", word_a: "เชฟ", word_b: "บาริสต้า" },
    UndercoverSeed { game_id: "uc_professions", label: "อาชีพ", word_a: "ครู", word_b: "ติวเตอร์" },
    // #35 uc_animals
    UndercoverSeed { game_id: "uc_animals", label: "สัตว์โลก", word_a: "เสือ", word_b: "สิงโต" },
    UndercoverSeed { game_id: "uc_animals", label: "สัตว์โลก", word_a: "โลมา", word_b: "วาฬ" },
    UndercoverSeed { game_id: "uc_animals", label: "สัตว์โลก", word_a: "เป็ด", word_b: "ห่าน" },
    // #36 uc_office_gear
    UndercoverSeed { game_id: "uc_office_gear", label: "ของใช้ออฟฟิศ", word_a: "ปากกาลูกลื่น", word_b: "ดินสอกด" },
    UndercoverSeed { game_id: "uc_office_gear", label: "ของใช้ออฟฟิศ", word_a: "คีย์บอร์ด", word_b: "เมาส์" },
    UndercoverSeed { game_id: "uc_office_gear", label: "ของใช้ออฟฟิศ", word_a: "แม็กเย็บกระดาษ", word_b: "คลิปหนีบกระดาษ" },
    // #37 uc_cafe_drinks
    UndercoverSeed { game_id: "uc_cafe_drinks", label: "เครื่องดื่มคาเฟ่", word_a: "ชาไทยเย็น", word_b: "ชานมไข่มุก" },
    UndercoverSeed { game_id: "uc_cafe_drinks", label: "เครื่องดื่มคาเฟ่", word_a: "ลาเต้", word_b: "คาปูชิโน" },
    UndercoverSeed { game_id: "uc_cafe_drinks", label: "เครื่องดื่มคาเฟ่", word_a: "โกโก้เย็น", word_b: "มอคค่าเย็น" },
    // #38 uc_home_items
    UndercoverSeed { game_id: "uc_home_items", label: "ของใช้ในบ้าน", word_a: "พัดลม", word_b: "เครื่องปรับอากาศ" },
    UndercoverSeed { game_id: "uc_home_items", label: "ของใช้ในบ้าน", word_a: "หมอนข้าง", word_b: "ผ้าห่ม" },
    UndercoverSeed { game_id: "uc_home_items", label: "ของใช้ในบ้าน", word_a: "ไม้กวาด", word_b: "ไม้ม็อบถูพื้น" },
    // #39 uc_sports
    UndercoverSeed { game_id: "uc_sports", label: "กีฬา", word_a: "แบดมินตัน", word_b: "เทนนิส" },
    UndercoverSeed { game_id: "uc_sports", label: "กีฬา", word_a: "ฟุตบอล", word_b: "ฟุตซอล" },
    UndercoverSeed { game_id: "uc_sports", label: "กีฬา", word_a: "ว่ายน้ำ", word_b: "ดำน้ำ" },
    // #40 uc_thai_festivals
    UndercoverSeed { game_id: "uc_thai_festivals", label: "เทศกาลไทย", word_a: "สงกรานต์", word_b: "ลอยกระทง" },
    UndercoverSeed { game_id: "uc_thai_festivals", label: "เทศกาลไทย", word_a: "วันปีใหม่", word_b: "วันตรุษจีน" },
    UndercoverSeed { game_id: "uc_thai_festivals", label: "เทศกาลไทย", word_a: "งานวัด", word_b: "ตลาดนัดกลางคืน" },
    // #41 uc_thai_desserts
    UndercoverSeed { game_id: "uc_thai_desserts", label: "ขนมไทย", word_a: "ทองหยิบ", word_b: "ทองหยอด" },
    UndercoverSeed { game_id: "uc_thai_desserts", label: "ขนมไทย", word_a: "ข้าวเหนียวมะม่วง", word_b: "ข้าวเหนียวทุเรียน" },
    UndercoverSeed { game_id: "uc_thai_desserts", label: "ขนมไทย", word_a: "บัวลอย", word_b: "ทับทิมกรอบ" },
    // #42 uc_vehicles
    UndercoverSeed { game_id: "uc_vehicles", label: "ยานพาหนะ", word_a: "รถตุ๊กตุ๊ก", word_b: "รถแท็กซี่" },
    UndercoverSeed { game_id: "uc_vehicles", label: "ยานพาหนะ", word_a: "รถไฟฟ้า", word_b: "รถไฟใต้ดิน" },
    UndercoverSeed { game_id: "uc_vehicles", label: "ยานพาหนะ", word_a: "จักรยาน", word_b: "มอเตอร์ไซค์" },
    // #43 uc_instruments
    UndercoverSeed { game_id: "uc_instruments", label: "เครื่องดนตรี", word_a: "กีตาร์", word_b: "อูคูเลเล่" },
    UndercoverSeed { game_id: "uc_instruments", label: "เครื่องดนตรี", word_a: "ระนาดเอก", word_b: "ขิม" },
    UndercoverSeed { game_id: "uc_instruments", label: "เครื่องดนตรี", word_a: "เปียโน", word_b: "คีย์บอร์ดไฟฟ้า" },
    // #44 uc_school_subjects
    UndercoverSeed { game_id: "uc_school_subjects", label: "วิชาเรียน", word_a: "ฟิสิกส์", word_b: "เคมี" },
    UndercoverSeed { game_id: "uc_school_subjects", label: "วิชาเรียน", word_a: "คณิตศาสตร์", word_b: "คอมพิวเตอร์" },
    UndercoverSeed { game_id: "uc_school_subjects", label: "วิชาเรียน", word_a: "ศิลปะ", word_b: "ดนตรี" },
    // #45 uc_supermarket
    UndercoverSeed { game_id: "uc_supermarket", label: "ซูเปอร์มาร์เก็ต", word_a: "น้ำปลา", word_b: "ซีอิ๊วขาว" },
    UndercoverSeed { game_id: "uc_supermarket", label: "ซูเปอร์มาร์เก็ต", word_a: "แชมพู", word_b: "ครีมนวดผม" },
    UndercoverSeed { game_id: "uc_supermarket", label: "ซูเปอร์มาร์เก็ต", word_a: "นมจืด", word_b: "นมถั่วเหลือง" },
];

pub fn fallback_undercover_pair(
    game: &GameCatalogItem,
    seed: u64,
) -> (&'static str, &'static str, &'static str) {
    let matched: Vec<&UndercoverSeed> = UNDERCOVER_BANK
        .iter()
        .filter(|p| p.game_id == game.id)
        .collect();
    let pool: Vec<&UndercoverSeed> = if matched.is_empty() {
        UNDERCOVER_BANK.iter().collect()
    } else {
        matched
    };

    let mut rng = SeedRng::new(seed ^ fnv1a_64(game.id));
    let pick = pool[(rng.next_u64() as usize) % pool.len()];
    if (rng.next_u64() & 1) == 0 {
        (pick.label, pick.word_a, pick.word_b)
    } else {
        (pick.label, pick.word_b, pick.word_a)
    }
}

// =============================================================================
// Curated Thai Fallback Bank 3: HINT_RACE (40 distinct 5-hint riddles — 2/game)
// =============================================================================

struct HintSeed {
    game_id: &'static str,
    category: &'static str,
    answer: &'static str,
    aliases: &'static [&'static str],
    hints: [&'static str; 5],
}

const HINT_BANK: &[HintSeed] = &[
    // #46 hint_menu_ingredients
    HintSeed {
        game_id: "hint_menu_ingredients",
        category: "ครอบครัว",
        answer: "ผัดกะเพรา",
        aliases: &["กะเพรา", "ข้าวกะเพรา", "กะเพราหมูสับ", "pad krapow"],
        hints: [
            "เมนูนี้ครองแชมป์อาหารตามสั่งที่คนไทยนึกถึงอันดับต้นๆ เวลาคิดไม่ออก",
            "ส่วนผสมตั้งต้นคือกระเทียมกับพริกตำผัดน้ำมันจนหอมฟุ้งชวนจาม",
            "ปรุงรสด้วยน้ำปลา ซอสหอยนางรม และน้ำตาลเล็กน้อย",
            "นิยมสั่งโปะคู่กับไข่ดาวกรอบไข่แดงเยิ้มๆ",
            "พระเอกใบสีเขียวกลิ่นเผ็ดร้อนที่อยู่ในชื่อเมนูคือใบกะเพรา",
        ],
    },
    HintSeed {
        game_id: "hint_menu_ingredients",
        category: "ครอบครัว",
        answer: "ส้มตำ",
        aliases: &["ส้มตำไทย", "ส้มตำปูปลาร้า", "ตำส้ม", "som tum"],
        hints: [
            "จานนี้ไม่ได้ผัดหรือต้ม แต่ใช้การโขลกในครกให้รสเข้าเนื้อ",
            "มีทั้งรสเปรี้ยว เผ็ด เค็ม และหวานกลมกล่อมในจานเดียว",
            "ใส่พริก กระเทียม มะเขือเทศ และถั่วฝักยาวเป็นสีสัน",
            "กินคู่กับข้าวเหนียวร้อนๆ และไก่ย่างคือฟินที่สุด",
            "วัตถุดิบเส้นกรอบสีขาวที่ขูดเป็นฝอยคือมะละกอดิบ",
        ],
    },
    // #47 hint_province_motto
    HintSeed {
        game_id: "hint_province_motto",
        category: "ความรู้",
        answer: "เชียงใหม่",
        aliases: &["chiang mai", "จ.เชียงใหม่", "จังหวัดเชียงใหม่"],
        hints: [
            "จังหวัดนี้เคยเป็นศูนย์กลางของอาณาจักรล้านนาอันรุ่งเรือง",
            "มีคูเมืองเก่าสี่เหลี่ยมและประตูท่าแพเป็นจุดถ่ายรูปยอดฮิต",
            "เป็นบ้านของยอดเขาที่สูงที่สุดในประเทศไทยอย่างดอยอินทนนท์",
            "เทศกาลยี่เป็งปล่อยโคมและถนนคนเดินวันอาทิตย์โด่งดังทั่วโลก",
            "ขึ้นดอยสุเทพไหว้พระธาตุคู่เมืองแล้วแวะเดินนิมมานฯ คือจังหวัดอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_province_motto",
        category: "ความรู้",
        answer: "ภูเก็ต",
        aliases: &["phuket", "จ.ภูเก็ต", "จังหวัดภูเก็ต"],
        hints: [
            "จังหวัดนี้มีลักษณะภูมิประเทศเป็นเกาะขนาดใหญ่ที่สุดของประเทศไทย",
            "ย่านเมืองเก่ามีตึกสไตล์ชิโน-โปรตุกีสสีพาสเทลสวยงาม",
            "มีจุดชมพระอาทิตย์ตกสุดโรแมนติกชื่อดังอย่างแหลมพรหมเทพ",
            "ได้รับฉายาว่า 'ไข่มุกแห่งอันดามัน'",
            "หาดป่าตอง หาดกะตะ และสะพานสารสิน อยู่ในจังหวัดอะไร?",
        ],
    },
    // #48 hint_job_tools
    HintSeed {
        game_id: "hint_job_tools",
        category: "ทำงาน",
        answer: "ทันตแพทย์",
        aliases: &["หมอฟัน", "dentist"],
        hints: [
            "งานนี้ต้องใช้แสงไฟส่องสว่างตรงจุดและสมาธิความละเอียดสูงมาก",
            "อุปกรณ์ประจำตัวมีกระจกจิ๋วด้ามยาวและเครื่องกรอเสียงชวนเสียว",
            "ผู้มาใช้บริการมักต้องเอนเก้าอี้ปรับระดับแล้วอ้าปากกว้างๆ",
            "ช่วยดูแลขูดหินปูน อุด หรือจัดเรียงระเบียบให้ยิ้มมั่นใจ",
            "เรียกสั้นๆ ติดปากกันทั่วไปว่า 'หมอฟัน'",
        ],
    },
    HintSeed {
        game_id: "hint_job_tools",
        category: "ทำงาน",
        answer: "บาริสต้า",
        aliases: &["barista", "คนชงกาแฟ"],
        hints: [
            "อาชีพนี้ต้องคุ้นเคยกับกลิ่นหอมและความแม่นยำเรื่องอุณหภูมิน้ำ",
            "อุปกรณ์คู่ใจคือเครื่องบด แทมเปอร์ และกาสตีมนมสเตนเลส",
            "ชงเครื่องดื่มตามสูตรร้อน เย็น หรือดริปให้ได้รสชาติคงที่",
            "บางคนมีสกิลเทฟองนมเป็นรูปหัวใจหรือใบไม้สุดละมุน",
            "ผู้เชี่ยวชาญการชงกาแฟประจำเคาน์เตอร์คาเฟ่เรียกว่าอะไร?",
        ],
    },
    // #49 hint_animal_habits
    HintSeed {
        game_id: "hint_animal_habits",
        category: "ครอบครัว",
        answer: "นกฮูก",
        aliases: &["นกเค้าแมว", "owl"],
        hints: [
            "สัตว์ชนิดนี้ขึ้นชื่อเรื่องการบินที่เงียบกริบแทบไม่มีเสียงลม",
            "มันไม่สามารถกลอกลูกตาไปมาได้ แต่หมุนคอได้กว้างถึงราว 270 องศา",
            "ออกหากินตอนกลางคืนเป็นหลักและมีสายตาคมกริบในที่มืด",
            "มักถูกใช้เป็นสัญลักษณ์ของความเฉลียวฉลาดและคนนอนดึก",
            "นกตาโตหน้าคล้ายแมวที่ร้องเสียง 'ฮูกๆ' คือสัตว์อะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_animal_habits",
        category: "ครอบครัว",
        answer: "เพนกวิน",
        aliases: &["นกเพนกวิน", "penguin"],
        hints: [
            "สัตว์ชนิดนี้จัดอยู่ในกลุ่มนก แต่ไม่สามารถบินขึ้นฟ้าได้",
            "มันใช้ปีกคู่สั้นๆ ว่ายน้ำได้คล่องแคล่วเหมือนตอร์ปิโดใต้ทะเล",
            "ส่วนใหญ่กระจายตัวอยู่ในซีกโลกใต้และบางสายพันธุ์ทนหนาวจัดได้เยี่ยม",
            "เวลาเดินบนบกจะเตาะแตะสลับซ้ายขวาหรือไถลท้องบนหิมะสุดน่ารัก",
            "นกชุดทักซิโดสีขาวดำขวัญใจขั้วโลกใต้คือสัตว์อะไร?",
        ],
    },
    // #50 hint_thai_idiom
    HintSeed {
        game_id: "hint_thai_idiom",
        category: "ความรู้",
        answer: "กิ้งก่าได้ทอง",
        aliases: &["กิ้งก่าได้ทอง"],
        hints: [
            "สำนวนไทยนี้เปรียบเทียบนิสัยคนผ่านสัตว์เลื้อยคลานตัวเล็กๆ",
            "ใช้อธิบายคนที่จู่ๆ ได้ดี มีตำแหน่ง หรือรวยขึ้นมากะทันหัน",
            "พอได้ดีแล้วก็เชิดหน้าชูคอ ทำท่าหยิ่งยโสอวดคนรอบข้าง",
            "ในสำนวนมีโลหะมีค่าสีเหลืองอร่ามเป็นของที่ได้มา",
            "สัตว์ที่ชอบผงกหัวพองคอ + ได้ของมีค่าสีเหลือง = สำนวนอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_thai_idiom",
        category: "ความรู้",
        answer: "ขี่ช้างจับตั๊กแตน",
        aliases: &["ขี่ช้างจับตั๊กแตน"],
        hints: [
            "สำนวนนี้พูดถึงการลงทุนลงแรงที่ไม่คุ้มกับผลลัพธ์ที่ได้กลับมา",
            "มีการเปรียบเทียบสัตว์ 2 ชนิดที่ขนาดต่างกันสุดขั้ว",
            "สัตว์ตัวแรกเป็นสัตว์บกขนาดยักษ์คู่บ้านคู่เมืองของไทย",
            "สัตว์ตัวที่สองเป็นแมลงตัวจิ๋วสีเขียวที่ชอบกระโดดตามทุ่งหญ้า",
            "ลงทุนเรื่องใหญ่โตแต่ได้ผลนิดเดียว เรียกว่า 'ขี่...จับ...'?",
        ],
    },
    // #51 hint_home_objects
    HintSeed {
        game_id: "hint_home_objects",
        category: "ครอบครัว",
        answer: "ร่ม",
        aliases: &["ร่มกันแดด", "ร่มกันฝน", "umbrella"],
        hints: [
            "ของชิ้นนี้มีทั้งแบบพับเก็บพกใส่กระเป๋าได้และแบบด้ามยาว",
            "เวลาไม่ได้ใช้จะหุบเรียบร้อย แต่พอใช้งานต้องกางออกเป็นทรงโดม",
            "โครงด้านในทำจากซี่โลหะหรือไฟเบอร์ที่ยึดผ้าใบไว้",
            "มักถูกลืมวางไว้ตามร้านอาหารหรือรถสาธารณะบ่อยที่สุดในหน้าฝน",
            "ของใช้ประจำวันสำหรับกันแดดและกันฝนเรียกว่าอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_home_objects",
        category: "ครอบครัว",
        answer: "กระจกเงา",
        aliases: &["กระจก", "mirror"],
        hints: [
            "ของสิ่งนี้ทำหน้าที่บอกความจริงตรงหน้าโดยไม่พูดสักคำ",
            "มักติดไว้ในห้องน้ำ โต๊ะเครื่องแป้ง หรือหน้าประตูบ้าน",
            "หากยกมือขวา สิ่งที่เห็นด้านในจะดูเหมือนยกด้านตรงข้าม",
            "เราใช้เช็กทรงผมและเสื้อผ้าก่อนออกจากบ้านทุกเช้า",
            "แผ่นแก้วเคลือบผิวสะท้อนภาพตัวเราเองเรียกว่าอะไร?",
        ],
    },
    // #52 hint_thai_landmarks
    HintSeed {
        game_id: "hint_thai_landmarks",
        category: "ความรู้",
        answer: "วัดอรุณ",
        aliases: &["วัดอรุณราชวราราม", "วัดแจ้ง", "wat arun"],
        hints: [
            "แลนด์มาร์กริมแม่น้ำเจ้าพระยาฝั่งธนบุรีที่นักท่องเที่ยวทั่วโลกหลงรัก",
            "โดดเด่นด้วยพระปรางค์องค์ใหญ่ประดับกระเบื้องเคลือบและเครื่องถ้วยหลากสี",
            "เดิมมีชื่อเรียกคุ้นปากว่า 'วัดแจ้ง'",
            "แสงยามเย็นและยามค่ำคืนที่ส่องพระปรางค์ริมน้ำสวยงามระดับโปสการ์ด",
            "วัดคู่บ้านคู่เมืองที่ชื่อแปลว่า 'รุ่งเช้า' คือวัดอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_thai_landmarks",
        category: "ความรู้",
        answer: "เยาวราช",
        aliases: &["ถนนเยาวราช", "yaowarat", "ไชน่าทาวน์"],
        hints: [
            "ย่านเก่าแก่ใจกลางกรุงเทพฯ ที่คึกคักทั้งกลางวันและกลางคืน",
            "กลางวันขึ้นชื่อเรื่องร้านทองและของแห้ง ส่วนกลางคืนคือสวรรค์ของสายกิน",
            "เอกลักษณ์คือป้ายไฟนีออนภาษาไทย-จีนสีสันสดใสตลอดสองข้างทาง",
            "เมนูดังมีทั้งก๋วยจั๊บ บะหมี่ ขนมปังปิ้งไส้ทะลัก และน้ำทับทิม",
            "ไชน่าทาวน์เมืองไทยที่มีซุ้มประตูเฉลิมพระเกียรติฯ คือย่านอะไร?",
        ],
    },
    // #53 hint_mystery_fruit
    HintSeed {
        game_id: "hint_mystery_fruit",
        category: "ครอบครัว",
        answer: "สับปะรด",
        aliases: &["pineapple", "บักนัด", "ยานัด"],
        hints: [
            "ผลไม้ชนิดนี้มีเอนไซม์ธรรมชาติที่ช่วยหมักเนื้อสัตว์ให้นุ่มได้",
            "บนหัวมีจุกใบแข็งสีเขียวคล้ายมงกุฎ",
            "ผิวด้านนอกมีลวดลายคล้ายตารอบผล ต้องปอกเฉือนตาออกก่อนกิน",
            "เนื้อสีเหลืองฉ่ำน้ำ รสหวานอมเปรี้ยว นิยมจิ้มพริกเกลือหรือทำข้าวผัด",
            "บางคนเอาไปใส่หน้าพิซซ่าจนเป็นศึกดีเบตทั่วโลก — ผลไม้อะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_mystery_fruit",
        category: "ครอบครัว",
        answer: "แตงโม",
        aliases: &["watermelon"],
        hints: [
            "ผลไม้ลูกโตที่มีส่วนประกอบเป็นน้ำมากกว่า 90% กินแล้วสดชื่นสุดๆ",
            "เปลือกหนาแข็งสีเขียวลายริ้วเข้ม",
            "ด้านในเนื้อสีแดงสด (หรือบางพันธุ์สีเหลือง) มีเมล็ดสีดำกระจายอยู่",
            "หน้าร้อนเมืองไทยนิยมเอามาปั่นใส่น้ำแข็งหรือกินคู่กับปลาแห้ง",
            "ผลไม้เนื้อแดงลูกกลมรีขวัญใจหน้าร้อนคืออะไร?",
        ],
    },
    // #54 hint_movie_plot
    HintSeed {
        game_id: "hint_movie_plot",
        category: "เพื่อน",
        answer: "รอมคอม",
        aliases: &["โรแมนติกคอมเมดี้", "หนังรักตลก", "romcom", "romantic comedy"],
        hints: [
            "แนวหนังที่ดูได้เพลินๆ เหมาะเปิดดูในคืนวันศุกร์กับเพื่อนหรือคนรู้ใจ",
            "ตัวเอกมักเริ่มต้นจากการไม่ถูกชะตากันหรือเข้าใจผิดกันแบบสุดป่วน",
            "มีแก๊งเพื่อนสนิทคอยชงมุกและให้คำปรึกษาสุดฮาตลอดเรื่อง",
            "กลางเรื่องมักมีฉากงอนกลางสายฝน ก่อนจะวิ่งตามไปง้อกันที่สนามบินหรือสถานีรถไฟ",
            "หนังรักหวานๆ ผสมมุกตลกยิ้มตามทั้งเรื่อง เรียกสั้นๆ ว่าแนวอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_movie_plot",
        category: "เพื่อน",
        answer: "สืบสวนสอบสวน",
        aliases: &["หนังนักสืบ", "สืบสวน", "detective", "mystery"],
        hints: [
            "คนดูหนังแนวนี้มักต้องสวมบทช่างสังเกตและจับผิดทุกฉาก",
            "ต้นเรื่องมักเกิดคดีปริศนา ของหาย หรือเหตุการณ์ลึกลับในห้องปิดตาย",
            "ตัวละครทุกคนในเรื่องดูมีพิรุธและแรงจูงใจน่าสงสัยไปหมด",
            "ช่วงท้ายจะมีฉากรวมตัวทุกคนแล้วเฉลยเบาะแสหักมุมทีละชิ้น",
            "แนวหนังที่มีพระเอกเป็นนักสืบไขคดีปริศนาคือแนวอะไร?",
        ],
    },
    // #55 hint_appliances
    HintSeed {
        game_id: "hint_appliances",
        category: "ครอบครัว",
        answer: "ไมโครเวฟ",
        aliases: &["เตาไมโครเวฟ", "microwave"],
        hints: [
            "ผู้ช่วยคู่ชีวิตของชาวหอและคนทำงานที่อยากกินของร้อนภายใน 1-2 นาที",
            "ด้านในมีจานแก้วหมุนวนเพื่อให้ความร้อนกระจายทั่วถึง",
            "ข้อห้ามสำคัญคือห้ามนำภาชนะโลหะหรือฟอยล์เข้าไปด้านในเด็ดขาด",
            "เมื่อครบเวลาจะมีเสียงดัง 'ติ๊ง!' บอกว่าอาหารพร้อมกินแล้ว",
            "เครื่องอุ่นอาหารด้วยคลื่นความร้อนคู่ครัวทุกบ้านคืออะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_appliances",
        category: "ครอบครัว",
        answer: "หม้อหุงข้าว",
        aliases: &["หม้อหุงข้าวไฟฟ้า", "rice cooker"],
        hints: [
            "เครื่องใช้ไฟฟ้าสามัญประจำบ้านของแทบทุกครอบครัวในเอเชีย",
            "ใช้งานง่ายแค่ตวงน้ำ กดปุ่มเดียว แล้วรอให้ดีดขึ้นเองเมื่อสุก",
            "หลายคนประยุกต์เอาไปต้มมาม่า นึ่งไข่ หรือทำเค้กได้ด้วย",
            "รุ่นใหม่มีโหมดอุ่นทิพย์เก็บความร้อนไว้ได้ตลอดวัน",
            "อุปกรณ์คู่ครัวสำหรับหุงข้าวสวยร้อนๆ คืออะไร?",
        ],
    },
    // #56 hint_thai_sweets
    HintSeed {
        game_id: "hint_thai_sweets",
        category: "ครอบครัว",
        answer: "ขนมครก",
        aliases: &["kanom krok"],
        hints: [
            "ขนมไทยโบราณที่ต้องหยอดลงหลุมกลมๆ บนเตาหลุมร้อนๆ",
            "มีส่วนผสมหลักคือแป้งข้าวเจ้าและหัวกะทิหอมมัน",
            "ขอบด้านนอกกรอบบาง ส่วนตรงกลางนุ่มละมุนหวานเค็มกำลังดี",
            "นิยมโรยหน้าด้วยต้นหอมซอย ข้าวโพด เผือก หรือฟักทอง",
            "เวลาขายพ่อค้าจะแคะมาประกบกันเป็นคู่กลมๆ — ขนมอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_thai_sweets",
        category: "ครอบครัว",
        answer: "ขนมชั้น",
        aliases: &["kanom chan"],
        hints: [
            "ขนมไทยมงคลที่มักใช้ในงานพิธีและงานเลี้ยงเพื่อสื่อถึงความเจริญก้าวหน้า",
            "เนื้อขนมเหนียวนุ่มหนึบหนับ หอมกลิ่นใบเตยและกะทิสด",
            "ต้องใจเย็นหยอดแป้งนึ่งสลับสีทีละแผ่นจนครบตามสูตร (นิยม 9 ชั้น)",
            "ตอนเด็กๆ หลายคนชอบดึงลอกกินทีละแผ่นแทนที่จะกัดทั้งคำ",
            "ขนมไทยนึ่งเป็นแผ่นซ้อนกันหลายๆ ชั้นเรียกว่าอะไร?",
        ],
    },
    // #57 hint_sport_rules
    HintSeed {
        game_id: "hint_sport_rules",
        category: "เพื่อน",
        answer: "ฟุตบอล",
        aliases: &["บอล", "football", "soccer"],
        hints: [
            "กีฬายอดนิยมอันดับต้นๆ ของโลกที่แบ่งการแข่งขันเป็น 2 ครึ่ง ครึ่งละ 45 นาที",
            "แต่ละทีมส่งผู้เล่นลงสนามพร้อมกันฝั่งละ 11 คน",
            "มีตำแหน่งพิเศษเพียง 1 คนต่อทีมที่ใช้มือจับลูกในเขตโทษได้",
            "ผู้ตัดสินพกใบเหลืองและใบแดงไว้ควบคุมกติกาในสนาม",
            "กีฬาที่เตะลูกกลมเข้าประตูฝั่งตรงข้ามเพื่อทำสกอร์เรียกว่าอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_sport_rules",
        category: "เพื่อน",
        answer: "บาสเกตบอล",
        aliases: &["บาส", "basketball"],
        hints: [
            "กีฬาในร่มที่เน้นความเร็วและการส่งบอลเป็นทีม ฝั่งละ 5 คน",
            "ผู้เล่นต้องเลี้ยงบอลเคาะพื้นเวลาเคลื่อนที่ ห้ามถือลูกวิ่งเฉยๆ",
            "การยิงทำคะแนนมีทั้งแบบ 1 แต้ม 2 แต้ม และยิงไกล 3 แต้ม",
            "ท่าทำคะแนนสุดเท่ที่คนดูเฮลั่นสนามคือการกระโดดดังก์",
            "กีฬาที่ชูตลูกสีส้มลงห่วงตาข่ายสูงเรียกว่าอะไร?",
        ],
    },
    // #58 hint_world_festivals
    HintSeed {
        game_id: "hint_world_festivals",
        category: "ความรู้",
        answer: "สงกรานต์",
        aliases: &["วันสงกรานต์", "เทศกาลสงกรานต์", "songkran"],
        hints: [
            "เทศกาลเฉลิมฉลองปีใหม่ตามประเพณีดั้งเดิมที่จัดช่วงกลางเดือนเมษายน",
            "มีพิธีสรงน้ำพระและรดน้ำดำหัวขอพรผู้ใหญ่เพื่อความเป็นสิริมงคล",
            "ก่อพระเจดีย์ทรายที่วัดและกลับมาพร้อมหน้าพร้อมตากับครอบครัว",
            "บรรยากาศทั่วเมืองเต็มไปด้วยเสียงหัวเราะ เสื้อลายดอก และความชุ่มฉ่ำ",
            "เทศกาลสาดน้ำดับร้อนสุดโด่งดังของประเทศไทยคืออะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_world_festivals",
        category: "ความรู้",
        answer: "ฮาโลวีน",
        aliases: &["วันฮาโลวีน", "halloween"],
        hints: [
            "เทศกาลสนุกสนานที่จัดขึ้นทุกวันที่ 31 ตุลาคมของทุกปี",
            "สัญลักษณ์ประจำงานคือโคมไฟที่แกะสลักจากผลฟักทองสีส้ม",
            "เด็กๆ ในต่างประเทศจะเดินเคาะประตูพูดว่า 'Trick or Treat' เพื่อขอขนม",
            "ผู้คนนิยมแต่งชุดแฟนซีแนวผี แม่มด หรือตัวละครสุดสร้างสรรค์",
            "คืนปล่อยผีสุดปาร์ตี้ปลายเดือนตุลาคมเรียกว่าวันอะไร?",
        ],
    },
    // #59 hint_thai_spoonerism
    HintSeed {
        game_id: "hint_thai_spoonerism",
        category: "ทายใจ/ฮา",
        answer: "สะดุ้ง",
        aliases: &["สะดุ้ง"],
        hints: [
            "คำนี้เป็นอาการที่เกิดขึ้นทันทีเวลาโดนเพื่อนแอบจ๊ะเอ๋จากข้างหลัง",
            "ลองผวนคำว่า 'ซุ้งดะ' ดูสิ จะได้เสียงคำนี้พอดี!",
            "ใช้บรรยายอาหารทะเลสดๆ อย่างเมนู 'กุ้ง...น้ำปลา' หรือ 'ปลาหมึก...มะนาว'",
            "ความหมายคือตกใจจนตัวโยนหรือขยับตัวพรวดพราด",
            "คำไทย 2 พยางค์ที่ผวนมาจาก 'ซุ้งดะ' คือคำว่าอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_thai_spoonerism",
        category: "ทายใจ/ฮา",
        answer: "ปลาหมึก",
        aliases: &["หมึก", "ปลาหมึกย่าง"],
        hints: [
            "เป็นสัตว์ทะเลที่นิยมเอามาย่างเสียบไม้จิ้มน้ำจิ้มซีฟู้ดแซ่บๆ",
            "ลองผวนคำว่า 'ปลึกหมา' แล้วจะร้องอ๋อทันที!",
            "มีหนวดหลายเส้นและพ่นหมึกสีดำได้เวลาตกใจ",
            "อยู่บนหน้าพิซซ่าซีฟู้ดและในจานผัดไข่เค็มสุดอร่อย",
            "คำผวนจาก 'ปลึกหมา' คือสัตว์ทะเลอะไร?",
        ],
    },
    // #60 hint_popular_acronyms
    HintSeed {
        game_id: "hint_popular_acronyms",
        category: "เพื่อน",
        answer: "WFH",
        aliases: &["wfh", "work from home", "ทำงานที่บ้าน"],
        hints: [
            "คำย่อภาษาอังกฤษ 3 ตัวอักษรที่ฮิตสุดๆ ในวงการคนทำงานยุคใหม่",
            "ข้อดีคือไม่ต้องฝ่ารถติดตอนเช้าและประชุมผ่านวิดีโอคอลได้",
            "ท่อนบนใส่เชิ้ตสุภาพเตรียมเปิดกล้อง แต่ท่อนล่างอาจเป็นกางเกงขาสั้น!",
            "ย่อมาจากประโยคว่า Work From Home",
            "คำย่อ 3 ตัวที่แปลว่า 'ทำงานจากที่บ้าน' คืออะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_popular_acronyms",
        category: "เพื่อน",
        answer: "OOTD",
        aliases: &["ootd", "outfit of the day"],
        hints: [
            "แฮชแท็กภาษาอังกฤษ 4 ตัวอักษรที่สายแฟชันและสายคาเฟ่ใช้ประจำ",
            "มักติดไว้ใต้รูปถ่ายเต็มตัวหน้ากระจกหรือมุมถ่ายรูปสวยๆ",
            "คำแรกย่อมาจาก Outfit ที่แปลว่าชุดแต่งกาย",
            "ความหมายเต็มคือ Outfit Of The Day",
            "คำย่อ 4 ตัวที่ใช้โชว์ 'ชุดแต่งตัวประจำวันนี้' คืออะไร?",
        ],
    },
    // #61 hint_country_food
    HintSeed {
        game_id: "hint_country_food",
        category: "ความรู้",
        answer: "ญี่ปุ่น",
        aliases: &["ประเทศญี่ปุ่น", "japan"],
        hints: [
            "ประเทศนี้พิถีพิถันเรื่องวัตถุดิบตามฤดูกาลและรสชาติอูมามิสุดๆ",
            "อาหารเส้นขึ้นชื่อมีทั้งราเมง อุด้ง และโซบะ",
            "มีวัฒนธรรมการดื่มชาเขียวมัทฉะและขนมโมจิหลากหลายรส",
            "เมนูข้าวปั้นหน้าปลาดิบสดๆ โด่งดังไปทั่วโลก",
            "บ้านเกิดของซูชิ ซาชิมิ และทาโกะยากิคือประเทศอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_country_food",
        category: "ความรู้",
        answer: "อิตาลี",
        aliases: &["ประเทศอิตาลี", "italy"],
        hints: [
            "ประเทศแถบยุโรปที่เป็นต้นตำรับวัฒนธรรมกาแฟเอสเปรสโซและคาปูชิโน",
            "ขึ้นชื่อเรื่องมะเขือเทศ น้ำมันมะกอก และชีสหลากหลายชนิด",
            "ของหวานยอดฮิตคือเจลาโต้เนื้อเนียนและทีรามิสุ",
            "อาหารเส้นอย่างสปาเกตตี คาโบนารา และลาซานญา มีต้นกำเนิดที่นี่",
            "บ้านเกิดของพิซซ่าและพาสต้าคือประเทศอะไร?",
        ],
    },
    // #62 hint_thai_flowers
    HintSeed {
        game_id: "hint_thai_flowers",
        category: "ครอบครัว",
        answer: "ดอกมะลิ",
        aliases: &["มะลิ", "jasmine"],
        hints: [
            "ดอกไม้ขนาดเล็กสีขาวบริสุทธิ์ที่มีกลิ่นหอมเย็นชื่นใจ",
            "นิยมนำมาร้อยเป็นพวงมาลัยสวยๆ เพื่อไหว้พระและมอบให้ผู้ใหญ่",
            "ใช้ลอยในน้ำเย็นเพิ่มความหอมสดชื่นในเมนูข้าวแช่ไทยโบราณ",
            "เป็นดอกไม้สัญลักษณ์ประจำวันแม่แห่งชาติของประเทศไทย",
            "ดอกไม้สีขาวกลิ่นหอมประจำวันแม่คือดอกอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_thai_flowers",
        category: "ครอบครัว",
        answer: "ดอกบัว",
        aliases: &["บัว", "lotus"],
        hints: [
            "พืชน้ำที่งอกงามขึ้นมาจากโคลนตมแต่ชูดอกสะอาดงดงามพ้นผิวน้ำ",
            "มีทั้งพันธุ์สีขาว สีชมพู และสีม่วง นิยมพับกลีบอย่างประณีต",
            "เมล็ดและรากของมันสามารถนำมาทำอาหารและขนมหวานได้อร่อย",
            "มักถูกใช้บูชาพระและเป็นสัญลักษณ์แห่งความสงบสติปัญญา",
            "ราชินีแห่งไม้น้ำที่คนไทยนิยมใช้ไหว้พระคือดอกอะไร?",
        ],
    },
    // #63 hint_popular_drinks
    HintSeed {
        game_id: "hint_popular_drinks",
        category: "เพื่อน",
        answer: "ชาไทย",
        aliases: &["ชาเย็น", "ชาไทยเย็น", "thai tea"],
        hints: [
            "เครื่องดื่มเย็นยอดฮิตที่ชาวต่างชาติมาไทยแล้วต้องตามหามาชิม",
            "มีสีส้มอำพันโดดเด่นเป็นเอกลักษณ์ไม่เหมือนชาชาติไหน",
            "ชงจากใบชาเข้มข้นผสมนมข้นหวานและราดนมข้นจืดปิดท้าย",
            "สั่งได้ตั้งแต่หวานร้อย หวานน้อย ไปจนหวานตัดขา!",
            "เครื่องดื่มชาสีส้มหอมมันขวัญใจร้านน้ำชงไทยคืออะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_popular_drinks",
        category: "เพื่อน",
        answer: "ชานมไข่มุก",
        aliases: &["ชาไข่มุก", "boba", "bubble tea"],
        hints: [
            "เครื่องดื่มสุดฮิตที่มีต้นกำเนิดจากไต้หวันและครองใจสายหวานทั่วเอเชีย",
            "ต้องใช้หลอดขนาดใหญ่พิเศษในการดูดเพื่อไม่ให้ติดค้าง",
            "ด้านล่างแก้วมีท็อปปิ้งเม็ดกลมสีเข้มเคี้ยวหนึบหนับ",
            "สามารถเลือกระดับความหวานและน้ำแข็งได้ตามใจชอบ",
            "ชานมใส่มุกเคี้ยวหนึบในแก้วฝาซีลเรียกว่าอะไร?",
        ],
    },
    // #64 hint_digital_jobs
    HintSeed {
        game_id: "hint_digital_jobs",
        category: "ทำงาน",
        answer: "โปรแกรมเมอร์",
        aliases: &["นักพัฒนาซอฟต์แวร์", "programmer", "developer", "dev"],
        hints: [
            "อาชีพนี้ใช้คีย์บอร์ดและหน้าจอคู่เป็นอาวุธหลักในการสร้างผลงาน",
            "คำที่ได้ยินบ่อยในชีวิตประจำวันคือ 'บั๊ก', 'ดีพลอย' และ 'คอมไพล์ผ่านแล้ว!'",
            "เปลี่ยนไอเดียให้กลายเป็นเว็บไซต์ แอปมือถือ หรือระบบหลังบ้าน",
            "มักมีกาแฟวางข้างโต๊ะและใช้ภาษาอย่าง Rust, TypeScript หรือ Python",
            "นักเขียนโค้ดสร้างแอปและซอฟต์แวร์เรียกว่าอาชีพอะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_digital_jobs",
        category: "ทำงาน",
        answer: "อินฟลูเอนเซอร์",
        aliases: &["ครีเอเตอร์", "ยูทูบเบอร์", "influencer", "creator"],
        hints: [
            "อาชีพยุคดิจิทัลที่ทำงานคู่กับกล้อง ไมโครโฟน และไฟวงแหวน",
            "ต้องคิดคอนเทนต์ รีวิวสินค้า หรือเล่าเรื่องให้น่าติดตามสม่ำเสมอ",
            "วัดความปังจากยอดวิว ยอดไลก์ และคอมเมนต์ของผู้ติดตาม",
            "สร้างแรงบันดาลใจด้านท่องเที่ยว อาหาร แฟชัน หรือความรู้บนโซเชียล",
            "ผู้สร้างคอนเทนต์ที่มีอิทธิพลต่อผู้ติดตามบนโลกออนไลน์เรียกว่าอะไร?",
        ],
    },
    // #65 hint_folk_riddles
    HintSeed {
        game_id: "hint_folk_riddles",
        category: "ครอบครัว",
        answer: "เทียนไข",
        aliases: &["เทียน", "candle"],
        hints: [
            "อะไรเอ่ย สูงเทียมฟ้า (ในความมืด) ยิ่งอยู่ยิ่งเตี้ยลงทุกที?",
            "มีไส้เชือกเส้นเล็กอยู่ตรงกลางลำตัว",
            "เวลาใช้งานต้องจุดไฟที่ปลายด้านบนเพื่อให้แสงสว่าง",
            "มักถูกปักบนเค้กวันเกิดหรือใช้จุดเวลาไฟดับ",
            "แท่งขี้ผึ้งที่ละลายเป็นน้ำตาเมื่อจุดไฟให้แสงสว่างคืออะไร?",
        ],
    },
    HintSeed {
        game_id: "hint_folk_riddles",
        category: "ครอบครัว",
        answer: "นาฬิกา",
        aliases: &["นาฬิกาข้อมือ", "clock", "watch"],
        hints: [
            "อะไรเอ่ย มีหน้าแต่ไม่มีปาก มีแขนแต่ไม่มีขา เดินวนได้ทั้งวันไม่เคยเหนื่อย?",
            "เสียงทำงานแบบดั้งเดิมดังเป็นจังหวะสม่ำเสมอ 'ติ๊กต็อก'",
            "มีตัวเลข 1 ถึง 12 เรียงรอบหน้าปัด (หรือแสดงเป็นตัวเลขดิจิทัล)",
            "ช่วยปลุกเราตอนเช้าและคอยเตือนไม่ให้ไปทำงานหรือนัดสาย",
            "อุปกรณ์บอกเวลาที่ติดผนังหรือสวมบนข้อมือเรียกว่าอะไร?",
        ],
    },
];

pub fn fallback_hint_items(
    game: &GameCatalogItem,
    count: usize,
    seed: u64,
) -> Vec<FallbackHintItem> {
    let mut tier1 = Vec::new();
    let mut tier2 = Vec::new();
    let mut tier3 = Vec::new();

    for (idx, h) in HINT_BANK.iter().enumerate() {
        if h.game_id == game.id {
            tier1.push(idx);
        } else if h.category == game.category {
            tier2.push(idx);
        } else {
            tier3.push(idx);
        }
    }

    let picked = select_prioritized_indices(
        tier1,
        tier2,
        tier3,
        count,
        seed ^ fnv1a_64(game.id),
    );

    picked
        .into_iter()
        .map(|idx| {
            let item = &HINT_BANK[idx];
            FallbackHintItem {
                answer: item.answer.to_string(),
                aliases: item.aliases.iter().map(|s| (*s).to_string()).collect(),
                hints: item.hints.iter().map(|s| (*s).to_string()).collect(),
            }
        })
        .collect()
}

// =============================================================================
// Curated Thai Fallback Bank 4: PARTY_VOTE (40 distinct dilemmas — 2 per game)
// =============================================================================

struct PartySeed {
    game_id: &'static str,
    category: &'static str,
    prompt: &'static str,
    options: &'static [&'static str],
    commentary: &'static str,
}

const PARTY_BANK: &[PartySeed] = &[
    // #66 vote_would_you_rather
    PartySeed {
        game_id: "vote_would_you_rather",
        category: "ทายใจ/ฮา",
        prompt: "ถ้าต้องเลือก 1 อย่างตลอดชีวิต คุณจะเลือกอะไร?",
        options: &[
            "กินบุฟเฟต์ฟรีตลอดชาติแต่ต้องเดินขึ้นบันไดทุกที่",
            "วาร์ปไปที่ไหนก็ได้ทันทีแต่ห้ามกินของหวานตลอดชีวิต",
        ],
        commentary: "สายกินกับสายขี้เกียจรถติดปะทะกันเดือดมาก! ใครยอมสละของหวานได้นี่ใจแข็งสุดๆ",
    },
    PartySeed {
        game_id: "vote_would_you_rather",
        category: "ทายใจ/ฮา",
        prompt: "เลือกความสามารถพิเศษสุดปั่น 1 อย่างสำหรับชีวิตประจำวัน!",
        options: &[
            "คุยกับหมาแมวรู้เรื่องทุกคำ",
            "ไม่ว่าจะนอนดึกแค่ไหนก็ตื่นมาสดชื่นเหมือนนอนครบ 8 ชั่วโมง",
        ],
        commentary: "มนุษย์นอนดึกเห็นข้อ 2 แล้วแทบกดปุ่มทะลุจอ ส่วนทาสแมวก็อยากรู้ว่าเจ้านายบ่นอะไร!",
    },
    // #67 vote_most_likely
    PartySeed {
        game_id: "vote_most_likely",
        category: "เพื่อน",
        prompt: "ในกลุ่มนี้ ใครมีโอกาสมากที่สุดที่จะตอบแชทว่า 'กำลังออกแล้ว' ทั้งที่ยังไม่อาบน้ำ?",
        options: &[
            "สายชิลประจำแก๊งมาสายแต่น่ารัก",
            "คนที่นัดเองแต่มาคนสุดท้าย",
            "ตัวฉันเองนี่แหละ ยอมรับก็ได้!",
            "ไม่มีเลย กลุ่มนี้ตรงเวลาทุกคน (จริงเหรอ?)",
        ],
        commentary: "คำว่า 'กำลังออกแล้ว' ในภาษาไทยมีความยืดหยุ่นทางเวลาตั้งแต่ 5 นาทีถึง 1 ชั่วโมงครึ่ง!",
    },
    PartySeed {
        game_id: "vote_most_likely",
        category: "เพื่อน",
        prompt: "ถ้าแก๊งนี้ไปเที่ยวต่างประเทศด้วยกัน ใครจะเป็นคนหลงทางเพราะมัวแต่แวะถ่ายรูป?",
        options: &[
            "สายคอนเทนต์กล้องพร้อมทุกมุม",
            "สายกินที่เดินตามกลิ่นของอร่อยไปเรื่อย",
            "หัวหน้าทริปที่ถือแผนที่แต่เดินผิดฝั่ง",
            "หลงพร้อมกันทั้งกลุ่มเลยสนุกดี!",
        ],
        commentary: "ทริปไหนไม่หลงทางสักรอบ แปลว่ายังเที่ยวไม่สุดจริงๆ!",
    },
    // #68 vote_desert_island
    PartySeed {
        game_id: "vote_desert_island",
        category: "เพื่อน",
        prompt: "เรือเสียจนต้องติดเกาะร้าง 7 วัน! อนุญาตให้พกของติดตัวขึ้นฝั่งได้แค่ 1 อย่าง คุณเลือกอะไร?",
        options: &[
            "มีดพับอเนกประสงค์ครบชุด",
            "หม้อต้มน้ำและไฟแช็กกันลม",
            "เปลญวนกับมุ้งกันยุงอย่างดี",
            "พาวเวอร์แบงก์โซลาร์เซลล์พร้อมมือถือ",
        ],
        commentary: "สายเอาตัวรอดเลือกมีดกับไฟ ส่วนสายสบายขอไม่โดนยุงกัดก่อน เรื่องอื่นค่อยว่ากัน!",
    },
    PartySeed {
        game_id: "vote_desert_island",
        category: "เพื่อน",
        prompt: "วันที่ 2 บนเกาะร้าง เจอกล่องปริศนาลอยมาเกยหาด 1 ใบ คุณจะตัดสินใจยังไง?",
        options: &[
            "รีบเปิดทันที เผื่อเป็นอาหารและน้ำดื่ม!",
            "เอาไม้ยาวๆ เขี่ยดูก่อนเพื่อความปลอดภัย",
            "ส่งเพื่อนที่ใจกล้าที่สุดเดินไปเปิดแทน",
        ],
        commentary: "สไตล์การเปิดกล่องบอกนิสัยได้เลย ใครเลือกส่งเพื่อนไปเปิดนี่มันสายวางแผนชัดๆ!",
    },
    // #69 vote_haunted_house
    PartySeed {
        game_id: "vote_haunted_house",
        category: "ทายใจ/ฮา",
        prompt: "เดินเข้าบ้านผีสิงแล้วจู่ๆ ไฟดับพรึ่บพร้อมเสียงหัวเราะเบาๆ คุณจะทำยังไงเป็นสิ่งแรก?",
        options: &[
            "เปิดไฟฉายมือถือแล้วตะโกนถามว่า 'ใครอยู่ตรงนั้น!'",
            "เกาะแขนคนข้างๆ แน่นจนอีกฝ่ายขยับไม่ได้",
            "ยืนนิ่งๆ แล้วสวดมนต์ทุกบทที่จำได้",
            "หันหลังเดินกลับทางเดิมแบบเนียนๆ",
        ],
        commentary: "คนถือไฟฉายคือความหวังหมู่บ้าน ส่วนสายหันหลังกลับมักรอดเป็นคนแรกในหนังทุกเรื่อง!",
    },
    PartySeed {
        game_id: "vote_haunted_house",
        category: "ทายใจ/ฮา",
        prompt: "คุณเจอประตู 3 บานในคฤหาสน์ปริศนา ต้องเลือกเปิด 1 บานเพื่อหาทางออก!",
        options: &[
            "ประตูไม้เก่าที่มีกลิ่นหอมขนมปังอบโชยออกมา",
            "ประตูสีแดงที่มีเสียงเพลงยุค 90 เปิดเบาๆ",
            "ประตูเหล็กเงียบกริบที่มีรอยเท้าแมวเดินเข้าไป",
        ],
        commentary: "ใครตามรอยเท้าแมวหรือกลิ่นขนมปังไป แปลว่าของกินกับน้องแมวชนะความกลัวได้เสมอ!",
    },
    // #70 vote_squad_mind
    PartySeed {
        game_id: "vote_squad_mind",
        category: "เพื่อน",
        prompt: "เวลานัดเจอแก๊งเพื่อนแบบไม่ได้วางแผนล่วงหน้า กิจกรรมไหนที่ลงเอยด้วยกันบ่อยที่สุด?",
        options: &[
            "หาร้านหมูกระทะหรือชาบูบุฟเฟต์",
            "นั่งคาเฟ่เม้าท์ยาวๆ จนร้านใกล้ปิด",
            "เดินห้างชอปปิงแล้วจบที่ร้านขนมหวาน",
            "รวมตัวเล่นเกมหรือดูหนังที่บ้านใครสักคน",
        ],
        commentary: "หมูกระทะกับคาเฟ่คือสองเสาหลักแห่งมิตรภาพที่ทำให้กลุ่มแชทคึกคักตลอดกาล!",
    },
    PartySeed {
        game_id: "vote_squad_mind",
        category: "เพื่อน",
        prompt: "ถ้าถ่ายรูปหมู่ 5 ช็อตแล้วมีคนหลับตา 1 คน แก๊งนี้จะจัดการยังไง?",
        options: &[
            "ถ่ายใหม่จนกว่าทุกคนจะรอด",
            "ลงรูปนั้นแหละ ตลกดีเป็นความทรงจำ!",
            "แปะสติกเกอร์น่ารักๆ ปิดหน้าคนหลับตา",
        ],
        commentary: "เพื่อนแท้จะไม่ทิ้งรูปหลุดของเพื่อน แต่จะเซฟเก็บไว้ส่งอวยพรวันเกิดปีหน้า!",
    },
    // #71 vote_family_mind
    PartySeed {
        game_id: "vote_family_mind",
        category: "ครอบครัว",
        prompt: "วันหยุดยาวทั้งที กิจกรรมครอบครัวแบบไหนที่ทำให้บ้านนี้อบอุ่นและสนุกที่สุด?",
        options: &[
            "ขับรถไปเที่ยวทะเลหรือภูเขาด้วยกัน",
            "ทำกับข้าวเมนูพิเศษกินพร้อมหน้ากันที่บ้าน",
            "ไปเดินตลาดของอร่อยแล้วแวะไหว้พระ",
            "เปิดหนังสนุกๆ ดูด้วยกันบนโซฟาทั้งบ้าน",
        ],
        commentary: "ไม่ว่าจะออกทริปหรือกินข้าวพร้อมหน้าที่บ้าน แค่ได้อยู่ด้วยกันก็คือวันหยุดที่คุ้มค่าที่สุดแล้ว!",
    },
    PartySeed {
        game_id: "vote_family_mind",
        category: "ครอบครัว",
        prompt: "เวลาซื้อของฝากกลับบ้าน ของแบบไหนที่คนในบ้านหยิบหมดไวที่สุด?",
        options: &[
            "ผลไม้สดตามฤดูกาลหวานๆ",
            "ขนมไทยหรือเบเกอรีอบใหม่",
            "ของกินเล่นกรุบกรอบเคี้ยวเพลิน",
            "กับข้าวถุงเจ้าดังแถวตลาด",
        ],
        commentary: "ของฝากสายกินไม่เคยเหลือข้ามคืน โดยเฉพาะถ้าวางกลางโต๊ะตอนเย็น!",
    },
    // #72 vote_office_drama
    PartySeed {
        game_id: "vote_office_drama",
        category: "ทำงาน",
        prompt: "บ่ายวันศุกร์ 16:45 น. มีข้อความเด้งว่า 'ขอแก้งานนิดเดียว' คุณจะตั้งสติด้วยวิธีไหน?",
        options: &[
            "สูดหายใจลึกๆ แล้วรีบปั่นให้จบก่อน 17:30 น.",
            "ถามขอบเขตให้ชัดและเสนอส่งเช้าวันจันทร์ถ้าไม่ด่วนจริง",
            "ชงกาแฟเย็นแก้วใหม่แล้วเปิดเพลงปลุกใจลุยเลย",
            "ส่งสติกเกอร์ยิ้มสู้ทั้งน้ำตาในใจ",
        ],
        commentary: "คำว่า 'นิดเดียว' ตอนเย็นวันศุกร์คือบททดสอบจิตใจขั้นสูงสุดของชาวออฟฟิศ!",
    },
    PartySeed {
        game_id: "vote_office_drama",
        category: "ทำงาน",
        prompt: "ประชุมออนไลน์กำลังเครียด แต่เผลอเปิดไมค์ตอนแมวร้องหรือเสียงรถขายกับข้าวผ่าน! คุณทำไง?",
        options: &[
            "รีบปิดไมค์แล้วเนียนคุยต่อเหมือนไม่มีอะไรเกิดขึ้น",
            "ยิ้มขำๆ แล้วแซวตัวเองเบาๆ ให้ห้องประชุมผ่อนคลาย",
            "อุ้มแมวโชว์หน้ากล้องซะเลย เปลี่ยนโหมดเป็นน่ารัก!",
        ],
        commentary: "รถกับข้าวกับน้องแมวคือแขกรับเชิญประจำห้องประชุมออนไลน์ที่ช่วยให้บรรยากาศหายตึงเสมอ!",
    },
    // #73 vote_dream_trip
    PartySeed {
        game_id: "vote_dream_trip",
        category: "เพื่อน",
        prompt: "เปิดโหวตจุดหมายทริปรอบหน้าของพวกเรา! อยากไปแนวไหนกันมากที่สุด?",
        options: &[
            "ทะเลน้ำใส นอนฟังเสียงคลื่นกินซีฟู้ด",
            "ภูเขาอากาศเย็น ชมหมอกจิบกาแฟดริป",
            "ตะลุยเมืองต่างประเทศ ชอปปิงกินสตรีทฟู้ด",
            "ทริปใกล้กรุง 2 วัน 1 คืน เน้นพักผ่อนและถ่ายรูปคาเฟ่",
        ],
        commentary: "โหวตจบปุ๊บอย่าลืมล็อกวันลางานเลยนะ ไม่งั้นทริปทิพย์จะอยู่กับเราไปอีกปี!",
    },
    PartySeed {
        game_id: "vote_dream_trip",
        category: "เพื่อน",
        prompt: "สไตล์ตารางเที่ยวในฝันของคุณตอนออกทริปเป็นแบบไหน?",
        options: &[
            "ตื่นเช้าเก็บครบทุกแลนด์มาร์ก คุ้มทุกนาที",
            "ตื่นสายๆ ชิลๆ ไปแค่วันละ 2 ที่ก็พอ",
            "เน้นตารางกินเป็นหลัก ที่เที่ยวคือของแถม!",
        ],
        commentary: "สายเก็บแลนด์มาร์กกับสายตื่นสายถ้าจับคู่กันได้สมดุลเมื่อไร ทริปนั้นสนุกคูณสอง!",
    },
    // #74 vote_dinner_decider
    PartySeed {
        game_id: "vote_dinner_decider",
        category: "ครอบครัว",
        prompt: "มื้อเย็นนี้ห้ามตอบว่า 'อะไรก็ได้'! โหวตเลยว่าอยากกินแนวไหนมากที่สุด?",
        options: &[
            "อาหารไทยรสจัด ส้มตำ-ยำ-กับข้าวร้อนๆ",
            "ปิ้งย่าง / ชาบู / หมูกระทะ เยียวยาทุกสิ่ง",
            "อาหารญี่ปุ่น ซูชิ ราเมง หรือข้าวหน้าต่างๆ",
            "ก๋วยเตี๋ยวหรือจานเดียวเจ้าเด็ดกินง่ายจบไว",
        ],
        commentary: "เย้! ในที่สุดเราก็ชนะคำต้องห้าม 'อะไรก็ได้' แล้ว เตรียมหยิบช้อนส้อมลุยได้เลย!",
    },
    PartySeed {
        game_id: "vote_dinner_decider",
        category: "ครอบครัว",
        prompt: "กินคาวแล้วต้องกินหวาน! ตบท้ายมื้อนี้ด้วยอะไรดี?",
        options: &[
            "บิงซูหรือไอศกรีมเย็นฉ่ำ",
            "ขนมปังปิ้ง-โทสต์หอมเนย",
            "ขนมไทยกะทิสดหรือบัวลอยไข่หวาน",
            "ชานมหรือผลไม้สดล้างปากเบาๆ",
        ],
        commentary: "กระเพาะของคาวกับกระเพาะของหวานแยกกันเสมอ วิทยาศาสตร์หัวใจยืนยันแล้ว!",
    },
    // #75 vote_spender_vs_saver
    PartySeed {
        game_id: "vote_spender_vs_saver",
        category: "ทายใจ/ฮา",
        prompt: "เจอของที่เล็งไว้นานจัดแฟลชเซลล์ลด 40% เหลืออีก 10 นาที! คุณเป็นสายไหน?",
        options: &[
            "กดใส่ตะกร้าแล้วจ่ายทันที ของมันต้องมี!",
            "ทักถามเพื่อนก่อนถ้าเพื่อนยุก็กดเลย",
            "ปิดแอปแล้วรออีก 24 ชั่วโมง ถ้ายังอยากได้ค่อยซื้อ",
            "ดูรีวิวจนหมดเวลาโปร แล้วค่อยโล่งใจว่าประหยัดไปได้เยอะ",
        ],
        commentary: "ข้อ 4 คือกลยุทธ์ประหยัดเงินแบบไม่ตั้งใจที่ช่วยรักษายอดบัญชีมาแล้วนักต่อนัก!",
    },
    PartySeed {
        game_id: "vote_spender_vs_saver",
        category: "ทายใจ/ฮา",
        prompt: "เงินเดือนออกวันแรก สิ่งแรกที่คุณมักจะทำคืออะไร?",
        options: &[
            "โอนเข้าบัญชีเก็บออมและจ่ายบิลให้ครบก่อนเลย",
            "จัดมื้ออร่อยให้รางวัลตัวเองที่สู้มาทั้งเดือน",
            "เคลียร์ของในตะกร้าชอปปิงที่ดองไว้ตั้งแต่วันที่ 20",
        ],
        commentary: "ออมก่อนใช้และให้รางวัลตัวเองพอดีๆ คือสูตรบาลานซ์ชีวิตที่ยอดเยี่ยมที่สุด!",
    },
    // #76 vote_lottery_30m
    PartySeed {
        game_id: "vote_lottery_30m",
        category: "ทายใจ/ฮา",
        prompt: "สมมติบ่ายวันนี้คุณถูกรางวัลใหญ่ 30 ล้านบาท! สิ่งแรกสุดที่จะทำคืออะไร?",
        options: &[
            "เก็บเงียบๆ วางแผนการเงินและปิดหนี้ทั้งหมดก่อน",
            "พาครอบครัวและแก๊งเพื่อนไปฉลองมื้อใหญ่สุดอลังการ",
            "ซื้อบ้านพร้อมสวนและที่ดินในฝันทันที",
            "แบ่งส่วนหนึ่งลงทุนกินปันผล แล้วแพ็กกระเป๋าเที่ยวรอบโลก",
        ],
        commentary: "ซ้อมวางแผนไว้ก่อนไม่เสียหาย เผื่องวดหน้าเป็นวันของเราจะได้ไม่ตื่นเต้นจนทำตัวไม่ถูก!",
    },
    PartySeed {
        game_id: "vote_lottery_30m",
        category: "ทายใจ/ฮา",
        prompt: "ถ้ามีเงิน 30 ล้านแล้ว วันจันทร์ถัดไปคุณจะยังไปทำงานเดิมไหม?",
        options: &[
            "ไปสิ! แต่ทำงานแบบชิลขึ้นและใจเย็นกับทุกเรื่องมากขึ้น",
            "ทำต่ออีกสักพักให้เรียบร้อยแล้วค่อยออกไปทำธุรกิจในฝัน",
            "ขอลาพักร้อนยาว 1 เดือนไปตั้งหลักก่อนตัดสินใจ",
        ],
        commentary: "ความมั่นคงทางการเงินช่วยให้ใจนิ่งขึ้นจริง แค่คิดก็รู้สึกวันจันทร์น่ารักขึ้น 300%!",
    },
    // #77 vote_superpower
    PartySeed {
        game_id: "vote_superpower",
        category: "ทายใจ/ฮา",
        prompt: "เลือกพลังวิเศษ 1 อย่างที่ใช้ได้จริงในชีวิตประจำวัน!",
        options: &[
            "วาร์ปไปที่ไหนก็ได้บนโลกใน 1 วินาที (บอกลารถติด)",
            "หยุดเวลาได้วันละ 1 ชั่วโมงเพื่อพักงีบหรือเคลียร์งาน",
            "พูดและเข้าใจได้ทุกภาษาบนโลกทันที",
            "เสกอาหารจานโปรดร้อนๆ ตรงหน้าได้วันละ 1 มื้อ",
        ],
        commentary: "พลังวาร์ปกับพลังเข้าใจทุกภาษานี่สูสีกันมาก ใครเลือกเสกอาหารคือรักการกินด้วยจิตวิญญาณ!",
    },
    PartySeed {
        game_id: "vote_superpower",
        category: "ทายใจ/ฮา",
        prompt: "หากได้พลังย้อนเวลาได้เพียง '5 นาที' ย้อนหลัง คุณจะเอาไว้ใช้กับเรื่องไหนบ่อยสุด?",
        options: &[
            "ย้อนกลับไปแก้คำพูดเวลาเผลอปล่อยไก่",
            "ย้อนกลับไปคว้าของที่ลืมก่อนปิดประตูบ้าน",
            "ย้อนกลับไปเลือกเมนูใหม่เวลาร้านสั่งมาแล้วจานเพื่อนดูน่ากินกว่า",
        ],
        commentary: "ย้อนเวลา 5 นาทีเพื่อเปลี่ยนเมนูอาหารคือพลังระดับจักรวาลที่สายกินทุกคนใฝ่ฝัน!",
    },
    // #78 vote_mini_detective
    PartySeed {
        game_id: "vote_mini_detective",
        category: "ทายใจ/ฮา",
        prompt: "คดีเค้กสตรอว์เบอร์รีหายจากตู้เย็นออฟฟิศ! พบ 3 เบาะแส — คุณสงสัยใครมากที่สุด?",
        options: &[
            "พี่เอ: บอกว่าไม่ได้เข้าครัว แต่มีครีมขาวติดมุมปากนิดเดียว",
            "น้องบี: ถือส้อมเดินผ่านครัว แต่บอกว่าเอาไปกินผลไม้",
            "คุณซี: บอกว่าไม่ชอบเค้ก แต่โพสต์รูปสตรอว์เบอร์รีสดเมื่อ 10 นาทีก่อน",
        ],
        commentary: "หลักฐานครีมติดมุมปากมันฟ้องชัดมาก! แต่เอ๊ะ...หรือจะเป็นการร่วมมือกันมากกว่า 1 คน?",
    },
    PartySeed {
        game_id: "vote_mini_detective",
        category: "ทายใจ/ฮา",
        prompt: "คดีรีโมตทีวีหายสาบสูญในบ้าน! นักสืบจะเริ่มค้นจุดไหนเป็นจุดแรก?",
        options: &[
            "ซอกเบาะโซฟา (หลุมดำแห่งบ้านทุกหลัง)",
            "ในตู้เย็น (เผลอถือไปพร้อมแก้วน้ำ)",
            "ใต้ผ้าห่มบนเตียงนอน",
            "ในมือคนที่กำลังช่วยหาอยู่นั่นแหละ!",
        ],
        commentary: "ซอกโซฟาคือสามเหลี่ยมเบอร์มิวดาของทุกบ้าน สถิติโลกยืนยันว่ารีโมตอยู่ตรงนั้นบ่อยสุด!",
    },
    // #79 vote_peak_habits
    PartySeed {
        game_id: "vote_peak_habits",
        category: "ทายใจ/ฮา",
        prompt: "สารภาพมาตรงๆ! นิสัยสุดพีกข้อไหนที่ตรงกับตัวคุณมากที่สุด?",
        options: &[
            "ตั้งนาฬิกาปลุกห่างกันทีละ 5 นาที รวมแล้วเกิน 5 รอบ",
            "เดินไปเปิดตู้เย็นยืนมองเฉยๆ แล้วปิด ทั้งที่รู้ว่าไม่มีอะไรใหม่",
            "ซ้อมบทพูดในใจอย่างดี พอเจอหน้าจริงพูดสั้นเหลือแค่ 'ครับ/ค่ะ'",
            "เป็นหมดทุกข้อเลย ยอมรับแบบภูมิใจ!",
        ],
        commentary: "การเปิดตู้เย็นเพื่อเช็กความคืบหน้าของจักรวาลเป็นกิจวัตรที่คนแทบทั้งโลกทำเหมือนกัน!",
    },
    PartySeed {
        game_id: "vote_peak_habits",
        category: "ทายใจ/ฮา",
        prompt: "เวลาฟังเพลงโปรดในรถหรือห้องน้ำ คุณอยู่ในเลเวลไหน?",
        options: &[
            "ฮัมเบาๆ แบบสุภาพชน",
            "ร้องเต็มเสียงประหนึ่งเปิดคอนเสิร์ตเดี่ยวรอบโลก",
            "เปิดซ้ำเพลงเดียววนไป 20 รอบจนกว่าจะหายอิน",
        ],
        commentary: "เสียงอะคูสติกในห้องน้ำทำให้ทุกคนกลายเป็นนักร้องเสียงทองได้ในพริบตา!",
    },
    // #80 vote_weekend_vibe
    PartySeed {
        game_id: "vote_weekend_vibe",
        category: "ครอบครัว",
        prompt: "เช้าวันเสาร์ที่ไม่มีนัดด่วน โหมดการใช้ชีวิตแบบไหนคือสวรรค์ของคุณ?",
        options: &[
            "นอนกลิ้งบนเตียงให้เต็มอิ่มแล้วค่อยหาบรันช์อร่อยๆ กิน",
            "ตื่นเช้าไปวิ่ง ออกกำลังกาย หรือเดินตลาดเช้า",
            "ชงกาแฟหอมๆ นั่งดูซีรีส์หรืออ่านหนังสือเงียบๆ",
            "ซักผ้า จัดบ้าน รีเฟรชห้องให้สะอาดหอมฟุ้ง",
        ],
        commentary: "วันหยุดที่ดีคือวันที่เราได้ชาร์จแบตในแบบที่ตัวเองสบายใจที่สุด!",
    },
    PartySeed {
        game_id: "vote_weekend_vibe",
        category: "ครอบครัว",
        prompt: "คืนวันอาทิตย์ตอน 3 ทุ่ม คุณมักจะกำลังทำอะไรอยู่?",
        options: &[
            "รีบดูซีรีส์อีกตอนก่อนนอน เดี๋ยวไม่คุ้มวันหยุด",
            "เตรียมเสื้อผ้า จัดตารางงานสำหรับวันจันทร์เรียบร้อย",
            "นั่งมองเพดานถามตัวเองว่าทำไมวันหยุดผ่านไปเร็วขนาดนี้!",
        ],
        commentary: "นาฬิกาวันเสาร์-อาทิตย์เดินเร็วกว่าวันธรรมดาเสมอ เป็นกฎฟิสิกส์ที่ยังไม่มีใครอธิบายได้!",
    },
    // #81 vote_save_world_5m
    PartySeed {
        game_id: "vote_save_world_5m",
        category: "ทายใจ/ฮา",
        prompt: "ยานเอเลี่ยนจอดเหนือกรุงเทพฯ และขอคุยกับตัวแทนมนุษย์โลกภายใน 5 นาที! คุณจะยื่นอะไรผูกมิตร?",
        options: &[
            "ข้าวเหนียวมะม่วงกับชาไทยเย็น ให้ชิมแล้วใจละลาย",
            "เปิดคลิปน้องแมวน่ารักๆ 10 คลิปรวด",
            "เชิญลงมาร้องคาราโอเกะและกินหมูกระทะด้วยกัน",
            "ส่งหัวหน้าแก๊งที่พูดเก่งที่สุดไปเจรจาแทน!",
        ],
        commentary: "การทูตด้วยข้าวเหนียวมะม่วงและคลิปแมวมีโอกาสกู้โลกสำเร็จสูงถึง 99.9%!",
    },
    PartySeed {
        game_id: "vote_save_world_5m",
        category: "ทายใจ/ฮา",
        prompt: "เอเลี่ยนบอกว่าถ้ามนุษย์ตอบถูกว่า 'อะไรคือความสุขที่สุดบนโลก' จะยอมกลับดาว! คุณเลือกตอบอะไร?",
        options: &[
            "ของกินอร่อยๆ กับคนที่รัก",
            "วันหยุดยาวพร้อมอากาศเย็นสบาย",
            "เสียงหัวเราะกับเพื่อนและครอบครัว",
        ],
        commentary: "ฟังคำตอบแล้วเอเลี่ยนอาจไม่อยากกลับดาว แต่อยากขออยู่เที่ยวเมืองไทยต่อเลย!",
    },
    // #82 vote_ayutthaya_portal
    PartySeed {
        game_id: "vote_ayutthaya_portal",
        category: "สร้างสรรค์",
        prompt: "จู่ๆ ประตูมิติพาคุณย้อนไปกรุงศรีอยุธยา! ถ้าเลือกพกทักษะยุคปัจจุบันไปทำมาหากินได้ 1 อย่าง เลือกอะไร?",
        options: &[
            "สูตรทำอาหารฟิวชันและขนมหวานสุดล้ำ เปิดร้านริมน้ำ",
            "ความรู้การค้าขายและบัญชี ช่วยวางระบบตลาด",
            "สกิลดนตรีและเล่านิทาน สร้างความบันเทิงทั่วพระนคร",
            "ความรู้การเกษตรและประดิษฐ์ของใช้ทุ่นแรง",
        ],
        commentary: "เปิดร้านอาหารริมน้ำกรุงศรีพร้อมโปรสะสมแต้ม น่าจะคิวยาวตั้งแต่ท่าน้ำยันตลาด!",
    },
    PartySeed {
        game_id: "vote_ayutthaya_portal",
        category: "สร้างสรรค์",
        prompt: "ไปถึงยุคอยุธยาวันแรก อยากไปเช็กอินทำกิจกรรมไหนก่อนเป็นอันดับแรก?",
        options: &[
            "พายเรือเที่ยวตลาดน้ำชิมขนมไทยโบราณสูตรต้นตำรับ",
            "เดินชมวัดวาอารามและงานช่างฝีมือสุดวิจิตร",
            "รีบหาซื้อผ้าไทยสวยๆ แต่งตัวให้เนียนเข้ายุคก่อน!",
        ],
        commentary: "แต่งตัวให้เนียนแล้วค่อยชิมของอร่อยทั่วตลาดน้ำ คือสูตรเที่ยวข้ามเวลาที่สมบูรณ์แบบ!",
    },
    // #83 vote_open_cafe_together
    PartySeed {
        game_id: "vote_open_cafe_together",
        category: "ทำงาน",
        prompt: "ถ้าพวกเราหุ้นกันเปิดร้านคาเฟ่ด้วยกัน 1 ร้าน คอนเซ็ปต์ไหนจะปังที่สุด?",
        options: &[
            "คาเฟ่สวนร่มรื่น โทนดินเผาอบอุ่น ถ่ายรูปสวยทุกมุม",
            "คาเฟ่ทำงาน Co-working เน็ตแรง ปลั๊กเพียบ กาแฟเด็ด",
            "คาเฟ่สัตว์เลี้ยงสุดน่ารัก มีน้องแมวต้อนรับ",
            "คาเฟ่ขนมไทยฟิวชัน กาแฟสเปเชียลตีคู่ขนมโบราณ",
        ],
        commentary: "คอนเซ็ปต์ชัดแบบนี้แค่คิดชื่อร้านก็อยากแวะไปอุดหนุนวันเปิดตัวแล้ว!",
    },
    PartySeed {
        game_id: "vote_open_cafe_together",
        category: "ทำงาน",
        prompt: "แบ่งหน้าที่กันในร้านคาเฟ่ของเรา คุณขอจองตำแหน่งไหน?",
        options: &[
            "บาริสต้าและเชฟคิดเมนูซิกเนเจอร์",
            "ฝ่ายการตลาด ถ่ายรูป คุมเพจ และจัดโปรปังๆ",
            "ผู้จัดการต้อนรับลูกค้าหน้าร้านและคุมบรรยากาศ",
            "ฝ่ายบัญชีคุมงบและตรวจชิมเมนูทุกวัน (หน้าที่สำคัญ!)",
        ],
        commentary: "ตำแหน่งตรวจชิมเมนูทุกวันมักเต็มไวที่สุดในทุกธุรกิจร้านอาหาร!",
    },
    // #84 vote_food_taste
    PartySeed {
        game_id: "vote_food_taste",
        category: "ทายใจ/ฮา",
        prompt: "ศึกดีเบตอาหารระดับชาติ! ผัดกะเพราที่ถูกต้องในใจคุณเป็นแบบไหน?",
        options: &[
            "ต้องมีแค่เนื้อสัตว์ พริก กระเทียม ใบกะเพรา ห้ามใส่ผักอื่น!",
            "ใส่ถั่วฝักยาวหรือข้าวโพดอ่อนนิดหน่อยก็อร่อยดีออก",
            "ใส่อะไรก็ได้ ขอแค่ผัดแห้งๆ หอมกะเพราและมีไข่ดาวกรอบ!",
        ],
        commentary: "สมรภูมิกะเพราไม่เคยแผ่ว! แต่ข้อ 3 พูดถูกใจมาก — ไข่ดาวขอบกรอบคือจุดเชื่อมสันติภาพ!",
    },
    PartySeed {
        game_id: "vote_food_taste",
        category: "ทายใจ/ฮา",
        prompt: "เวลาสั่งก๋วยเตี๋ยว เส้นไหนคือเดอะเบสต์ตลอดกาลของคุณ?",
        options: &["เส้นเล็กเหนียวนุ่ม", "บะหมี่เหลือง", "เส้นหมี่ขาว", "เส้นใหญ่หรือวุ้นเส้น"],
        commentary: "ทีมเส้นเล็กกับทีมบะหมี่มักครองเสียงข้างมาก แต่ทีมเส้นหมี่ก็เหนียวแน่นไม่แพ้กัน!",
    },
    // #85 vote_telepathy_test
    PartySeed {
        game_id: "vote_telepathy_test",
        category: "เพื่อน",
        prompt: "วัดพลังโทรจิต! พูดคำว่า 'ของอร่อยหน้าร้อน' คุณนึกถึงอย่างแรกคืออะไร?",
        options: &["ข้าวเหนียวมะม่วง", "ไอศกรีม", "น้ำแข็งไส/บิงซู", "แตงโมแช่เย็น"],
        commentary: "ถ้าทุกคนกดตรงกันเกินครึ่ง แปลว่าคลื่นสมองสายกินของห้องนี้จูนตรงกันระดับ 5G!",
    },
    PartySeed {
        game_id: "vote_telepathy_test",
        category: "เพื่อน",
        prompt: "โทรจิตรอบตัดสิน! ถ้าต้องเลือก 1 ฤดูให้อยู่กับเมืองไทยทั้งปี จะเลือกฤดูไหน?",
        options: &["ฤดูหนาวเย็นสบาย", "ฤดูฝนฉ่ำๆ นอนเพลิน", "ฤดูร้อนแดดจ้าเที่ยวทะเล", "สลับกันครบ 3 ฤดูนี่แหละดีแล้ว"],
        commentary: "ดูผลโหวตแล้วรู้เลยว่าใครคือคนขี้ร้อนและใครคือสายฝนชุ่มฉ่ำประจำห้อง!",
    },
];

pub fn fallback_party_rounds(
    game: &GameCatalogItem,
    count: usize,
    seed: u64,
) -> Vec<FallbackPartyRound> {
    let mut tier1 = Vec::new();
    let mut tier2 = Vec::new();
    let mut tier3 = Vec::new();

    for (idx, p) in PARTY_BANK.iter().enumerate() {
        if p.game_id == game.id {
            tier1.push(idx);
        } else if p.category == game.category {
            tier2.push(idx);
        } else {
            tier3.push(idx);
        }
    }

    let picked = select_prioritized_indices(
        tier1,
        tier2,
        tier3,
        count,
        seed ^ fnv1a_64(game.id),
    );

    picked
        .into_iter()
        .map(|idx| {
            let item = &PARTY_BANK[idx];
            FallbackPartyRound {
                prompt: item.prompt.to_string(),
                options: item.options.iter().map(|s| (*s).to_string()).collect(),
                commentary: item.commentary.to_string(),
            }
        })
        .collect()
}

// =============================================================================
// Curated Thai Fallback Bank 5: CREATIVE_CHALLENGE (33 prompts — incl. Vision)
// =============================================================================

struct ChallengeSeed {
    game_id: &'static str,
    category: &'static str,
    prompt: &'static str,
    tip: &'static str,
    requires_image: bool,
}

const CHALLENGE_BANK: &[ChallengeSeed] = &[
    // #86 create_two_line_poem
    ChallengeSeed {
        game_id: "create_two_line_poem",
        category: "สร้างสรรค์",
        prompt: "แต่งกลอนหรือคำคล้องจอง 2 วรรค ในหัวข้อ 'เงินเดือนออกแล้วหายไปไหน'",
        tip: "เน้นสัมผัสนอกคล้องจอง อ่านแล้วขำหรือจี๊ดใจรับคะแนนพิเศษ!",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_two_line_poem",
        category: "สร้างสรรค์",
        prompt: "แต่งกลอนสั้น 2 วรรค ชวนเพื่อนหรือครอบครัวไปกินมื้ออร่อยเย็นนี้",
        tip: "ใส่ชื่อเมนูเด็ดลงไปด้วยจะยิ่งชวนหิวและคะแนนพุ่ง!",
        requires_image: false,
    },
    // #87 create_funny_caption
    ChallengeSeed {
        game_id: "create_funny_caption",
        category: "ทายใจ/ฮา",
        prompt: "ตั้งแคปชันฮาๆ ประกอบรูป 'ถือแก้วกาแฟทำหน้าจริงจังในเช้าวันจันทร์'",
        tip: "สั้น กระชับ กวนเบาๆ อ่านแล้วคนอยากกดหัวเราะ",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_funny_caption",
        category: "ทายใจ/ฮา",
        prompt: "ตั้งแคปชันสุดปั่นสำหรับรูป 'บอกว่าลดน้ำหนัก แต่ตรงหน้ามีชาบูเต็มโต๊ะ'",
        tip: "หาเหตุผลเข้าข้างตัวเองให้เนียนที่สุด!",
        requires_image: false,
    },
    // #88 create_shop_name
    ChallengeSeed {
        game_id: "create_shop_name",
        category: "ทำงาน",
        prompt: "ตั้งชื่อ 'ร้านข้าวผัดกะเพราเปิดดึก' ให้จำง่าย ติดหู และคนอยากลองสั่ง!",
        tip: "แถมคำโปรยสั้นๆ ต่อท้ายชื่อร้านได้อีกนิด ยิ่งดูมือโปร",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_shop_name",
        category: "ทำงาน",
        prompt: "ตั้งชื่อ 'ร้านคาเฟ่แมวสไตล์ไทยร่วมสมัย' ที่ฟังปุ๊บอยากแวะเช็กอินทันที",
        tip: "ผสมคำไทยน่ารักๆ กับความอบอุ่นจะโดนใจกรรมการสุดๆ",
        requires_image: false,
    },
    // #89 create_late_excuse
    ChallengeSeed {
        game_id: "create_late_excuse",
        category: "ทำงาน",
        prompt: "คิดข้ออ้างมาสายสุดสร้างสรรค์แนวตลกที่ฟังแล้วเพื่อนหรือหัวหน้าหลุดขำแทนที่จะโกรธ!",
        tip: "ยิ่งจินตนาการล้ำแต่เล่าเหมือนเรื่องจริง ยิ่งได้คะแนนความคิดสร้างสรรค์",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_late_excuse",
        category: "ทำงาน",
        prompt: "แต่งข้ออ้างน่ารักๆ เมื่อลืมตอบแชทเพื่อนไป 3 วันเต็ม!",
        tip: "ผสมความจริงใจกับมุกขำๆ ให้เพื่อนหายงอนทันที",
        requires_image: false,
    },
    // #90 create_monday_quote
    ChallengeSeed {
        game_id: "create_monday_quote",
        category: "ทำงาน",
        prompt: "แต่งคำคมวันจันทร์ 1 ประโยคที่อ่านแล้วตาสว่าง มีแรงฮึดลุยงานต่อ!",
        tip: "จะแนวให้กำลังใจอบอุ่นหรือแนวตลกปลอบใจก็ได้หมด",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_monday_quote",
        category: "ทำงาน",
        prompt: "เขียนคติประจำใจยามบ่าย 3 โมงตอนง่วงสุดขีดแต่เดดไลน์ยังไม่จบ!",
        tip: "สั้น คม โดนใจมนุษย์ทำงานทุกสายอาชีพ",
        requires_image: false,
    },
    // #91 create_wacky_slogan
    ChallengeSeed {
        game_id: "create_wacky_slogan",
        category: "สร้างสรรค์",
        prompt: "ตั้งสโลแกนขาย 'หมอนหนุนธรรมดา' ให้ฟังดูหรูหราอลังการจนคนต้องรีบกดสั่ง!",
        tip: "เล่นคำคล้องจองหรือเปรียบเทียบสุดเวอร์วังแบบสร้างสรรค์",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_wacky_slogan",
        category: "สร้างสรรค์",
        prompt: "ตั้งสโลแกนขาย 'พัดลมพกพาขนาดจิ๋ว' สำหรับหน้าร้อนเมืองไทยให้ปังสุดๆ!",
        tip: "พูดถึงแดดเมืองไทยแบบขำๆ รับรองเข้าเป้า",
        requires_image: false,
    },
    // #92 create_turn_bad_funny
    ChallengeSeed {
        game_id: "create_turn_bad_funny",
        category: "ทายใจ/ฮา",
        prompt: "เพิ่งล้างรถเสร็จไม่ถึง 10 นาที ฝนก็เทลงมา! พลิกเรื่องนี้ให้เป็นมุกปลอบใจพลังบวก",
        tip: "มองมุมกลับแบบขำๆ ให้อ่านแล้วยิ้มออกทันที",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_turn_bad_funny",
        category: "ทายใจ/ฮา",
        prompt: "เดินออกจากบ้านสวยหล่อเต็มที่ แต่เพิ่งรู้ว่าลืมพกหูฟัง! เปลี่ยนวันนี้ให้กลายเป็นเรื่องสนุกใน 1 ประโยค",
        tip: "ใช้จินตนาการสร้างมุมมองใหม่ที่อบอุ่นและตลก",
        requires_image: false,
    },
    // #93 create_emoji_story
    ChallengeSeed {
        game_id: "create_emoji_story",
        category: "สร้างสรรค์",
        prompt: "แต่งเรื่องสั้น 1-2 ประโยคเชื่อมโยงอีโมจิทั้ง 4 ตัวนี้: 🐱 🚀 🍜 ⏰",
        tip: "ขอให้มีครบทั้งแมว จรวด ก๋วยเตี๋ยว และนาฬิกาในเรื่องเดียวกัน!",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_emoji_story",
        category: "สร้างสรรค์",
        prompt: "แต่งเรื่องสุดปั่นจากชุดอีโมจิ 4 ตัวนี้: 🌧️ 🛺 🥭 🎸",
        tip: "ผูกเรื่องให้มีทั้งฝน รถตุ๊กตุ๊ก มะม่วง และกีตาร์แบบเนียนๆ",
        requires_image: false,
    },
    // #94 create_one_line_intro
    ChallengeSeed {
        game_id: "create_one_line_intro",
        category: "เพื่อน",
        prompt: "แนะนำตัวเองใน 1 ประโยค หากคุณคือซูเปอร์ฮีโร่ที่มีพลังพิเศษด้าน 'การกินและการนอน'",
        tip: "ตั้งฉายาเท่ๆ แถมมาด้วยจะยิ่งปัง!",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_one_line_intro",
        category: "เพื่อน",
        prompt: "แนะนำตัวเองใน 1 ประโยคให้เพื่อนใหม่จำคุณได้แม่นที่สุดโดยไม่บอกชื่อจริง",
        tip: "หยิบเอกลักษณ์หรือของโปรดมาเล่าแบบน่ารักน่าจดจำ",
        requires_image: false,
    },
    // #95 create_fusion_menu
    ChallengeSeed {
        game_id: "create_fusion_menu",
        category: "สร้างสรรค์",
        prompt: "คิดเมนูฟิวชันใหม่ที่รวม 'ต้มยำกุ้ง' เข้ากับ 'ขนมหรืออาหารตะวันตก' พร้อมตั้งชื่อเมนูสุดเก๋!",
        tip: "บอกชื่อเมนูและอธิบายความอร่อยสั้นๆ ให้เชฟอยากลองทำตาม",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_fusion_menu",
        category: "สร้างสรรค์",
        prompt: "จับคู่ 'ชาไทย' กับวัตถุดิบสุดคาดไม่ถึง 1 อย่าง แล้วปั้นเป็นเมนูซิกเนเจอร์ประจำร้าน!",
        tip: "คิดชื่อเมนูให้น่าสั่งและอธิบายรสชาติให้ชวนชิม",
        requires_image: false,
    },
    // #96 create_warm_blessing
    ChallengeSeed {
        game_id: "create_warm_blessing",
        category: "ครอบครัว",
        prompt: "เขียนคำอวยพรสั้นๆ สุดอบอุ่นให้คนในห้องแชทนี้มีสัปดาห์ที่สดใสและราบรื่น",
        tip: "ข้อความจริงใจและเป็นกันเองจะได้คะแนนความอบอุ่นเต็มร้อย",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_warm_blessing",
        category: "ครอบครัว",
        prompt: "ส่งข้อความให้กำลังใจคนใกล้ตัวที่กำลังเหนื่อยจากงานหรือการเรียนใน 1-2 ประโยค",
        tip: "อ่านแล้วรู้สึกมีพลังใจและยิ้มตามได้ทันที",
        requires_image: false,
    },
    // #97 create_word_chain
    ChallengeSeed {
        game_id: "create_word_chain",
        category: "สร้างสรรค์",
        prompt: "แต่งประโยคเดียวที่ใช้ครบทั้ง 3 คำนี้ให้เนียนที่สุด: 'หมูกระทะ', 'ดาวอังคาร', 'รองเท้าแตะ'",
        tip: "ต้องมีครบทั้ง 3 คำในประโยคเดียว ยิ่งลื่นไหลยิ่งคะแนนสูง!",
        requires_image: false,
    },
    ChallengeSeed {
        game_id: "create_word_chain",
        category: "สร้างสรรค์",
        prompt: "แต่งประโยคสุดล้ำที่มีครบทั้ง 3 คำนี้: 'กาแฟเย็น', 'ร่มสีเหลือง', 'แมวส้ม'",
        tip: "ร้อยเรื่องให้น่ารักหรือตลกหักมุมได้เต็มที่!",
        requires_image: false,
    },
    // #98 create_photo_red (Vision — 3 dedicated photo prompts)
    ChallengeSeed {
        game_id: "create_photo_red",
        category: "สร้างสรรค์",
        prompt: "ภารกิจถ่ายรูป! หาสิ่งของ 'สีแดง' ที่อยู่ใกล้ตัวคุณที่สุดตอนนี้ ถ่ายส่งมาพร้อมแคปชันสั้นๆ",
        tip: "แนบภาพส่งในห้องแชทแล้วเลือกส่งเข้าเกม ให้ BC AI ตรวจสีและให้คะแนน!",
        requires_image: true,
    },
    ChallengeSeed {
        game_id: "create_photo_red",
        category: "สร้างสรรค์",
        prompt: "ภารกิจล่าสีสัน! ถ่ายภาพสิ่งของ 'สีส้มหรือโทนดินเผา' ใกล้ตัวคุณตอนนี้ พร้อมตั้งชื่อให้มัน 1 ชื่อ",
        tip: "ถ่ายให้เห็นชัดๆ แสงดีๆ BC AI พร้อมคอมเมนต์ความเก๋ให้เลย",
        requires_image: true,
    },
    ChallengeSeed {
        game_id: "create_photo_red",
        category: "สร้างสรรค์",
        prompt: "ภารกิจถ่ายรูปของทรงกลม! หาสิ่งของ 'ทรงกลม' รอบตัวคุณ 1 ชิ้นแล้วแชะภาพส่งมาอวดกัน",
        tip: "แก้วน้ำ นาฬิกา เหรียญ หรือของแต่งโต๊ะก็ได้หมด ขอแค่กลมจริง!",
        requires_image: true,
    },
    // #99 create_photo_fav_corner (Vision — 3 dedicated photo prompts)
    ChallengeSeed {
        game_id: "create_photo_fav_corner",
        category: "สร้างสรรค์",
        prompt: "ภารกิจถ่ายรูปมุมโปรด! แชะภาพ 'มุมโต๊ะทำงานหรือมุมพักผ่อน' ของคุณตอนนี้พร้อมบรรยายฟีล 1 ประโยค",
        tip: "ไม่ต้องจัดบ้านใหม่ก็ได้ ความเรียลคือเสน่ห์ที่ BC AI ชอบมาก!",
        requires_image: true,
    },
    ChallengeSeed {
        game_id: "create_photo_fav_corner",
        category: "สร้างสรรค์",
        prompt: "ภารกิจอวดวิว! ถ่ายภาพ 'วิวท้องฟ้าหรือมุมมองนอกหน้าต่าง' ใกล้คุณตอนนี้ส่งมาแชร์บรรยากาศกัน",
        tip: "บอกด้วยว่าอากาศแถวบ้านคุณตอนนี้เป็นยังไงบ้าง",
        requires_image: true,
    },
    ChallengeSeed {
        game_id: "create_photo_fav_corner",
        category: "สร้างสรรค์",
        prompt: "ภารกิจของคู่ใจ! ถ่ายภาพ 'สิ่งของ 1 ชิ้นบนโต๊ะที่คุณขาดไม่ได้ทุกวัน' พร้อมเหตุผลสั้นๆ",
        tip: "อาจเป็นแก้วใบโปรด ปากกาคู่ใจ หรือตุ๊กตาให้กำลังใจก็ได้",
        requires_image: true,
    },
    // #100 create_photo_food_drink (Vision — 3 dedicated photo prompts)
    ChallengeSeed {
        game_id: "create_photo_food_drink",
        category: "สร้างสรรค์",
        prompt: "ภารกิจอวดความอร่อย! ถ่ายภาพ 'อาหาร ขนม หรือแก้วเครื่องดื่ม' ที่อยู่ตรงหน้าคุณตอนนี้ให้เชฟ BC AI รีวิว!",
        tip: "หากไม่มีอาหารตรงหน้า ถ่ายขวดน้ำหรือของว่างใกล้ตัวแล้วตั้งชื่อเมนูให้หรูสุดๆ ได้เลย",
        requires_image: true,
    },
    ChallengeSeed {
        game_id: "create_photo_food_drink",
        category: "สร้างสรรค์",
        prompt: "ภารกิจแก้วคู่ใจ! ถ่ายภาพ 'แก้วน้ำหรือเครื่องดื่มดับกระหาย' ของคุณวันนี้พร้อมให้คะแนนความสดชื่นเต็ม 10",
        tip: "ถ่ายมุมสวยๆ ให้แสงเข้าแก้ว เชฟ AI พร้อมกดคะแนนให้เต็มที่",
        requires_image: true,
    },
    ChallengeSeed {
        game_id: "create_photo_food_drink",
        category: "สร้างสรรค์",
        prompt: "ภารกิจเสบียงเติมพลัง! ถ่ายภาพ 'ของกินเล่นหรือผลไม้' ใกล้ตัวแล้วเขียนรีวิวรสชาติ 1 บรรทัด",
        tip: "แนบรูปส่งเข้าเกมเพื่อให้ BC AI วิเคราะห์ความน่ากินแบบจัดเต็ม!",
        requires_image: true,
    },
];

pub fn fallback_challenge_prompts(
    game: &GameCatalogItem,
    count: usize,
    seed: u64,
) -> Vec<FallbackChallengePrompt> {
    let wants_image = CHALLENGE_BANK
        .iter()
        .any(|c| c.game_id == game.id && c.requires_image);

    let mut tier1 = Vec::new();
    let mut tier2 = Vec::new();
    let mut tier3 = Vec::new();

    for (idx, c) in CHALLENGE_BANK.iter().enumerate() {
        if c.game_id == game.id {
            tier1.push(idx);
        } else if c.requires_image == wants_image && c.category == game.category {
            tier2.push(idx);
        } else if c.requires_image == wants_image {
            tier3.push(idx);
        }
    }

    let picked = select_prioritized_indices(
        tier1,
        tier2,
        tier3,
        count,
        seed ^ fnv1a_64(game.id),
    );

    picked
        .into_iter()
        .map(|idx| {
            let item = &CHALLENGE_BANK[idx];
            FallbackChallengePrompt {
                prompt: item.prompt.to_string(),
                tip: item.tip.to_string(),
                requires_image: item.requires_image,
            }
        })
        .collect()
}

// =============================================================================
// Unit Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn catalog_has_exact_100_unique_valid_games() {
        assert_eq!(GAME_CATALOG.len(), 100);

        let valid_categories: HashSet<&str> = GAME_CATEGORIES.iter().copied().collect();
        let valid_modes: HashSet<&str> = ["solo", "group", "both"].into_iter().collect();
        let valid_engines: HashSet<&str> = [
            "quiz",
            "undercover",
            "hint_race",
            "party_vote",
            "creative_challenge",
        ]
        .into_iter()
        .collect();

        let mut seen_ids = HashSet::new();
        let mut seen_names = HashSet::new();
        let mut engine_counts = std::collections::HashMap::new();

        for (idx, game) in GAME_CATALOG.iter().enumerate() {
            assert_eq!(game.number, (idx + 1) as u16, "number mismatch at idx {}", idx);
            assert!(!game.id.is_empty());
            assert!(
                game.id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "invalid slug: {}",
                game.id
            );
            assert!(seen_ids.insert(game.id), "duplicate id: {}", game.id);
            assert!(!game.name.trim().is_empty());
            assert!(seen_names.insert(game.name), "duplicate name: {}", game.name);
            assert!(!game.tagline.trim().is_empty());
            assert!(!game.emoji.trim().is_empty());
            assert!(!game.ai_topic_hint.trim().is_empty());
            assert!(
                valid_categories.contains(game.category),
                "invalid category '{}' for {}",
                game.category,
                game.id
            );
            assert!(
                valid_modes.contains(game.play_mode),
                "invalid play_mode '{}' for {}",
                game.play_mode,
                game.id
            );
            assert!(
                valid_engines.contains(game.engine),
                "invalid engine '{}' for {}",
                game.engine,
                game.id
            );

            match game.play_mode {
                "solo" | "both" => assert_eq!(game.min_players, 1, "min_players for {}", game.id),
                "group" => assert_eq!(game.min_players, 2, "min_players for {}", game.id),
                _ => unreachable!(),
            }

            let expected_rounds = match game.engine {
                "quiz" | "party_vote" => 5,
                "hint_race" | "creative_challenge" => 3,
                "undercover" => 1,
                _ => unreachable!(),
            };
            assert_eq!(
                game.default_rounds, expected_rounds,
                "default_rounds for {}",
                game.id
            );

            *engine_counts.entry(game.engine).or_insert(0usize) += 1;
            assert_eq!(find_game_by_id(game.id), Some(game));
        }

        assert_eq!(engine_counts.get("quiz").copied().unwrap_or(0), 30);
        assert_eq!(engine_counts.get("undercover").copied().unwrap_or(0), 15);
        assert_eq!(engine_counts.get("hint_race").copied().unwrap_or(0), 20);
        assert_eq!(engine_counts.get("party_vote").copied().unwrap_or(0), 20);
        assert_eq!(engine_counts.get("creative_challenge").copied().unwrap_or(0), 15);
    }

    #[test]
    fn every_game_produces_valid_non_empty_fallback_content() {
        for game in &GAME_CATALOG {
            let rounds = game.default_rounds as usize;
            match game.engine {
                "quiz" => {
                    let pack = fallback_quiz_pack(game, rounds, 42);
                    assert_eq!(pack.len(), rounds, "quiz count for {}", game.id);
                    for q in &pack {
                        assert!(!q.question.trim().is_empty());
                        assert_eq!(q.options.len(), 4, "quiz options for {}", game.id);
                        assert!(q.correct_index < 4, "quiz correct_index for {}", game.id);
                        assert!(!q.explanation.trim().is_empty());
                    }
                }
                "undercover" => {
                    let (cat, civ, spy) = fallback_undercover_pair(game, 42);
                    assert!(!cat.trim().is_empty());
                    assert!(!civ.trim().is_empty());
                    assert!(!spy.trim().is_empty());
                    assert_ne!(civ, spy, "undercover words equal for {}", game.id);
                }
                "hint_race" => {
                    let items = fallback_hint_items(game, rounds, 42);
                    assert_eq!(items.len(), rounds, "hint count for {}", game.id);
                    for h in &items {
                        assert!(!h.answer.trim().is_empty());
                        assert!(!h.aliases.is_empty());
                        assert_eq!(h.hints.len(), 5, "hint levels for {}", game.id);
                        assert!(h.hints.iter().all(|s| !s.trim().is_empty()));
                    }
                }
                "party_vote" => {
                    let items = fallback_party_rounds(game, rounds, 42);
                    assert_eq!(items.len(), rounds, "party count for {}", game.id);
                    for p in &items {
                        assert!(!p.prompt.trim().is_empty());
                        assert!(
                            (2..=4).contains(&p.options.len()),
                            "party options for {}",
                            game.id
                        );
                        assert!(!p.commentary.trim().is_empty());
                    }
                }
                "creative_challenge" => {
                    let items = fallback_challenge_prompts(game, rounds, 42);
                    assert_eq!(items.len(), rounds, "challenge count for {}", game.id);
                    let expect_img = game.id.starts_with("create_photo_");
                    for c in &items {
                        assert!(!c.prompt.trim().is_empty());
                        assert!(!c.tip.trim().is_empty());
                        assert_eq!(
                            c.requires_image, expect_img,
                            "requires_image mismatch for {}",
                            game.id
                        );
                    }
                }
                other => panic!("unexpected engine: {}", other),
            }
        }
    }

    #[test]
    fn filter_and_pick_random_game_respect_mode_category_and_excludes() {
        assert_eq!(filter_catalog(None, None, None).len(), 100);
        assert_eq!(filter_catalog(Some("all"), None, None).len(), 100);

        let solo_games = filter_catalog(Some("solo"), None, None);
        assert!(!solo_games.is_empty());
        assert!(solo_games
            .iter()
            .all(|g| g.play_mode == "solo" || g.play_mode == "both"));
        assert!(solo_games.iter().all(|g| g.min_players == 1));

        let group_games = filter_catalog(Some("group"), None, None);
        assert!(!group_games.is_empty());
        assert!(group_games
            .iter()
            .all(|g| g.play_mode == "group" || g.play_mode == "both"));

        for &cat in &GAME_CATEGORIES {
            let solo_cat = filter_catalog(Some("solo"), Some(cat), None);
            let group_cat = filter_catalog(Some("group"), Some(cat), None);
            assert!(!solo_cat.is_empty(), "category '{}' has no solo games", cat);
            assert!(!group_cat.is_empty(), "category '{}' has no group games", cat);

            let picked_solo = pick_random_game("solo", Some(cat), &[], 12345);
            assert_eq!(picked_solo.category, cat);
            assert!(picked_solo.play_mode == "solo" || picked_solo.play_mode == "both");

            let picked_group = pick_random_game("group", Some(cat), &[], 12345);
            assert_eq!(picked_group.category, cat);
            assert!(picked_group.play_mode == "group" || picked_group.play_mode == "both");
        }

        // Excluding almost all solo games in "สร้างสรรค์" forces picking the remaining one
        let creative_solo = filter_catalog(Some("solo"), Some("สร้างสรรค์"), None);
        assert!(creative_solo.len() >= 2);
        let excluded: Vec<String> = creative_solo[..creative_solo.len() - 1]
            .iter()
            .map(|g| g.id.to_string())
            .collect();
        let last_expected = creative_solo[creative_solo.len() - 1];
        let picked = pick_random_game("solo", Some("สร้างสรรค์"), &excluded, 999);
        assert_eq!(picked.id, last_expected.id);

        // Excluding ALL matching games falls back safely instead of panicking
        let all_excluded: Vec<String> = creative_solo.iter().map(|g| g.id.to_string()).collect();
        let fallback_pick = pick_random_game("solo", Some("สร้างสรรค์"), &all_excluded, 999);
        assert_eq!(fallback_pick.category, "สร้างสรรค์");

        // Search query matches Thai name / number / id
        let found_food = filter_catalog(None, None, Some("อาหารไทย"));
        assert!(found_food.iter().any(|g| g.id == "quiz_thai_food"));
        let found_num = filter_catalog(None, None, Some("100"));
        assert!(found_num.iter().any(|g| g.number == 100));
    }

    #[test]
    fn fallback_banks_meet_minimum_richness_and_uniqueness() {
        assert!(QUIZ_BANK.len() >= 25);
        assert!(UNDERCOVER_BANK.len() >= 30);
        assert!(HINT_BANK.len() >= 20);
        assert!(PARTY_BANK.len() >= 20);
        assert!(CHALLENGE_BANK.len() >= 15);

        let quiz_qs: HashSet<&str> = QUIZ_BANK.iter().map(|q| q.question).collect();
        assert_eq!(quiz_qs.len(), QUIZ_BANK.len(), "duplicate quiz question");

        let uc_pairs: HashSet<(&str, &str)> =
            UNDERCOVER_BANK.iter().map(|u| (u.word_a, u.word_b)).collect();
        assert_eq!(uc_pairs.len(), UNDERCOVER_BANK.len(), "duplicate undercover pair");

        let hint_answers: HashSet<&str> = HINT_BANK.iter().map(|h| h.answer).collect();
        assert_eq!(hint_answers.len(), HINT_BANK.len(), "duplicate hint answer");

        let party_prompts: HashSet<&str> = PARTY_BANK.iter().map(|p| p.prompt).collect();
        assert_eq!(party_prompts.len(), PARTY_BANK.len(), "duplicate party prompt");

        let chal_prompts: HashSet<&str> = CHALLENGE_BANK.iter().map(|c| c.prompt).collect();
        assert_eq!(chal_prompts.len(), CHALLENGE_BANK.len(), "duplicate challenge prompt");
    }
}
