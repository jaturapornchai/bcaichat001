use calamine::{open_workbook_auto_from_rs, Reader as SpreadsheetReader};
use quick_xml::{escape::unescape, events::Event, Reader as XmlReader};
use std::io::{Cursor, Read};
use zip::ZipArchive;

pub const MAX_EXTRACTED_CHARS: usize = 8_000;
pub const MAX_DOCUMENT_DOWNLOAD_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_IMAGE_VISION_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_SPREADSHEET_ROWS_PER_SHEET: usize = 200;
pub const MAX_SPREADSHEET_SHEETS: usize = 20;
pub const SCANNED_PDF_NOTE: &str =
    "ไม่พบข้อความที่คัดลอกได้ในไฟล์ PDF นี้ คาดว่าเป็นไฟล์ PDF แบบสแกนภาพหรือภาพถ่ายหน้ากระดาษ แนะนำให้แคปหน้าจอหรือส่งเป็นรูปภาพเพื่อให้ AI อ่านภาพได้โดยตรง";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentKind {
    Image,
    Document,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DocumentFormat {
    Pdf,
    Docx,
    Pptx,
    Spreadsheet,
    PlainText,
}

fn file_extension(file_name: &str) -> String {
    file_name
        .trim()
        .rsplit_once('.')
        .map(|(_, ext)| ext.trim().to_ascii_lowercase())
        .unwrap_or_default()
}

fn base_mime(mime_type: &str) -> String {
    mime_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase()
}

pub fn is_pdf_attachment(mime_type: &str, file_name: &str) -> bool {
    base_mime(mime_type) == "application/pdf" || file_extension(file_name) == "pdf"
}

fn detect_document_format(mime_type: &str, file_name: &str) -> Option<DocumentFormat> {
    let ext = file_extension(file_name);
    let mime = base_mime(mime_type);

    if ext == "pdf" || mime == "application/pdf" {
        return Some(DocumentFormat::Pdf);
    }
    if ext == "docx"
        || mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    {
        return Some(DocumentFormat::Docx);
    }
    if ext == "pptx"
        || mime == "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    {
        return Some(DocumentFormat::Pptx);
    }
    if matches!(ext.as_str(), "xlsx" | "xls" | "ods" | "xlsb")
        || matches!(
            mime.as_str(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                | "application/vnd.ms-excel"
                | "application/vnd.oasis.opendocument.spreadsheet"
        )
    {
        return Some(DocumentFormat::Spreadsheet);
    }
    if matches!(
        ext.as_str(),
        "txt"
            | "md"
            | "csv"
            | "tsv"
            | "json"
            | "xml"
            | "html"
            | "htm"
            | "yaml"
            | "yml"
            | "toml"
            | "ini"
            | "log"
            | "sql"
            | "rs"
            | "ts"
            | "tsx"
            | "js"
            | "py"
            | "dart"
            | "css"
    ) || mime.starts_with("text/")
        || matches!(
            mime.as_str(),
            "application/json" | "application/xml" | "application/x-yaml" | "application/yaml"
        )
    {
        return Some(DocumentFormat::PlainText);
    }
    None
}

pub fn classify_attachment(mime_type: &str, file_name: &str) -> AttachmentKind {
    let ext = file_extension(file_name);
    let mime = base_mime(mime_type);

    if matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "webp" | "gif")
        || matches!(
            mime.as_str(),
            "image/png" | "image/jpeg" | "image/jpg" | "image/webp" | "image/gif"
        )
    {
        return AttachmentKind::Image;
    }

    if detect_document_format(mime_type, file_name).is_some() {
        return AttachmentKind::Document;
    }

    AttachmentKind::Unsupported
}

pub fn canonical_image_mime(mime_type: &str, file_name: &str) -> &'static str {
    let ext = file_extension(file_name);
    let mime = base_mime(mime_type);
    match (mime.as_str(), ext.as_str()) {
        ("image/png", _) | (_, "png") => "image/png",
        ("image/webp", _) | (_, "webp") => "image/webp",
        ("image/gif", _) | (_, "gif") => "image/gif",
        _ => "image/jpeg",
    }
}

pub fn cap_extracted_text(raw: &str, max_chars: usize) -> String {
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");
    let mut collapsed = String::with_capacity(normalized.len().min(max_chars * 4));
    let mut consecutive_blanks = 0usize;
    for line in normalized.lines() {
        let trimmed_end = line.trim_end();
        if trimmed_end.trim().is_empty() {
            consecutive_blanks += 1;
            if consecutive_blanks <= 1 && !collapsed.is_empty() {
                collapsed.push('\n');
            }
        } else {
            consecutive_blanks = 0;
            if !collapsed.is_empty() {
                collapsed.push('\n');
            }
            collapsed.push_str(trimmed_end);
        }
    }
    let clean = collapsed.trim();
    if clean.chars().count() <= max_chars {
        return clean.to_string();
    }
    let truncated: String = clean.chars().take(max_chars).collect();
    format!("{}\n...[ตัดข้อความบางส่วน]...", truncated.trim_end())
}

fn decode_plain_text(bytes: &[u8]) -> String {
    let stripped = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    match std::str::from_utf8(stripped) {
        Ok(s) => s.trim_start_matches('\u{FEFF}').to_string(),
        Err(_) => String::from_utf8_lossy(stripped)
            .trim_start_matches('\u{FEFF}')
            .to_string(),
    }
}

fn extract_pdf_text(bytes: &[u8]) -> Result<String, String> {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        pdf_extract::extract_text_from_mem(bytes)
    }));
    match res {
        Ok(Ok(text)) => {
            if text.trim().is_empty() {
                Ok(String::new())
            } else {
                Ok(cap_extracted_text(&text, MAX_EXTRACTED_CHARS))
            }
        }
        Ok(Err(e)) => Err(format!("ไม่สามารถแยกข้อความจากไฟล์ PDF ได้: {e}")),
        Err(_) => Err(
            "ไม่สามารถอ่านโครงสร้างไฟล์ PDF นี้ได้ (ไฟล์อาจเสียหายหรือมีการเข้ารหัส)".to_string(),
        ),
    }
}

fn decode_xml_text(raw: &quick_xml::events::BytesText<'_>) -> String {
    let s: &str = raw.as_ref();
    match unescape(s) {
        Ok(u) => u.into_owned(),
        Err(_) => s.to_owned(),
    }
}

fn extract_word_xml_text(xml: &str) -> String {
    let mut reader = XmlReader::from_str(xml);
    reader.config_mut().trim_text(false);

    let mut out = String::new();
    let mut in_text = false;
    let mut in_cell = false;
    let mut current_cell = String::new();
    let mut current_row_cells: Vec<String> = Vec::new();
    let mut in_row = false;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => match e.local_name().as_ref() {
                "t" => in_text = true,
                "tr" => {
                    in_row = true;
                    current_row_cells.clear();
                }
                "tc" => {
                    in_cell = true;
                    current_cell.clear();
                }
                "br" | "cr" => {
                    if in_cell {
                        current_cell.push(' ');
                    } else {
                        out.push('\n');
                    }
                }
                "tab" => {
                    if in_cell {
                        current_cell.push(' ');
                    } else {
                        out.push('\t');
                    }
                }
                _ => {}
            },
            Ok(Event::Empty(e)) => match e.local_name().as_ref() {
                "br" | "cr" => {
                    if in_cell {
                        current_cell.push(' ');
                    } else {
                        out.push('\n');
                    }
                }
                "tab" => {
                    if in_cell {
                        current_cell.push(' ');
                    } else {
                        out.push('\t');
                    }
                }
                _ => {}
            },
            Ok(Event::Text(t)) => {
                if in_text {
                    let piece = decode_xml_text(&t);
                    if in_cell {
                        current_cell.push_str(&piece);
                    } else {
                        out.push_str(&piece);
                    }
                }
            }
            Ok(Event::CData(c)) => {
                if in_text {
                    let piece: &str = c.as_ref();
                    if in_cell {
                        current_cell.push_str(piece);
                    } else {
                        out.push_str(piece);
                    }
                }
            }
            Ok(Event::End(e)) => match e.local_name().as_ref() {
                "t" => in_text = false,
                "p" => {
                    if in_cell {
                        if !current_cell.trim().is_empty() && !current_cell.ends_with(' ') {
                            current_cell.push(' ');
                        }
                    } else if !out.ends_with('\n') {
                        out.push('\n');
                    }
                }
                "tc" => {
                    in_cell = false;
                    let cleaned = current_cell.trim().to_string();
                    if in_row {
                        current_row_cells.push(cleaned);
                    } else if !cleaned.is_empty() {
                        out.push_str(&cleaned);
                        out.push('\n');
                    }
                    current_cell.clear();
                }
                "tr" => {
                    in_row = false;
                    let non_empty = current_row_cells.iter().any(|c| !c.is_empty());
                    if non_empty {
                        if !out.is_empty() && !out.ends_with('\n') {
                            out.push('\n');
                        }
                        out.push_str(&current_row_cells.join(" | "));
                        out.push('\n');
                    }
                    current_row_cells.clear();
                }
                _ => {}
            },
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }

    out
}

fn extract_docx_text(bytes: &[u8]) -> Result<String, String> {
    let mut archive = ZipArchive::new(Cursor::new(bytes))
        .map_err(|e| format!("ไม่สามารถเปิดไฟล์ DOCX ได้: {e}"))?;

    let mut headers: Vec<String> = Vec::new();
    let mut footers: Vec<String> = Vec::new();
    let mut has_document = false;

    for i in 0..archive.len() {
        if let Ok(file) = archive.by_index(i) {
            if let Ok(name_cow) = file.name() {
                let name = name_cow.into_owned();
                if name == "word/document.xml" {
                    has_document = true;
                } else if name.starts_with("word/header") && name.ends_with(".xml") {
                    headers.push(name);
                } else if name.starts_with("word/footer") && name.ends_with(".xml") {
                    footers.push(name);
                }
            }
        }
    }
    headers.sort();
    footers.sort();

    let mut ordered_parts = Vec::new();
    ordered_parts.extend(headers);
    if has_document {
        ordered_parts.push("word/document.xml".to_string());
    }
    ordered_parts.extend(footers);

    if ordered_parts.is_empty() {
        return Err("ไม่พบเนื้อหาเอกสาร (word/document.xml) ในไฟล์ DOCX".to_string());
    }

    let mut combined = String::new();
    for part in ordered_parts {
        if let Ok(mut entry) = archive.by_name(&part) {
            let mut xml = String::new();
            if entry.read_to_string(&mut xml).is_ok() {
                let text = extract_word_xml_text(&xml);
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    if !combined.is_empty() {
                        combined.push_str("\n\n");
                    }
                    combined.push_str(trimmed);
                }
            }
        }
    }

    Ok(cap_extracted_text(&combined, MAX_EXTRACTED_CHARS))
}

fn extract_pptx_slide_xml_text(xml: &str) -> String {
    let mut reader = XmlReader::from_str(xml);
    reader.config_mut().trim_text(false);

    let mut out = String::new();
    let mut in_text = false;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => match e.local_name().as_ref() {
                "t" => in_text = true,
                "br" => out.push('\n'),
                _ => {}
            },
            Ok(Event::Empty(e)) => {
                if e.local_name().as_ref() == "br" {
                    out.push('\n');
                }
            }
            Ok(Event::Text(t)) => {
                if in_text {
                    out.push_str(&decode_xml_text(&t));
                }
            }
            Ok(Event::CData(c)) => {
                if in_text {
                    out.push_str(c.as_ref());
                }
            }
            Ok(Event::End(e)) => match e.local_name().as_ref() {
                "t" => in_text = false,
                "p" => {
                    if !out.ends_with('\n') {
                        out.push('\n');
                    }
                }
                _ => {}
            },
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }

    out
}

fn extract_pptx_text(bytes: &[u8]) -> Result<String, String> {
    let mut archive = ZipArchive::new(Cursor::new(bytes))
        .map_err(|e| format!("ไม่สามารถเปิดไฟล์ PPTX ได้: {e}"))?;

    let mut slides: Vec<(u32, String)> = Vec::new();
    for i in 0..archive.len() {
        if let Ok(file) = archive.by_index(i) {
            if let Ok(name_cow) = file.name() {
                let name = name_cow.into_owned();
                if let Some(rest) = name.strip_prefix("ppt/slides/slide") {
                    if let Some(num_str) = rest.strip_suffix(".xml") {
                        if let Ok(num) = num_str.parse::<u32>() {
                            slides.push((num, name));
                        }
                    }
                }
            }
        }
    }
    slides.sort_by_key(|(n, _)| *n);

    if slides.is_empty() {
        return Err("ไม่พบสไลด์ในไฟล์ PPTX".to_string());
    }

    let mut combined = String::new();
    for (num, path) in slides {
        if let Ok(mut entry) = archive.by_name(&path) {
            let mut xml = String::new();
            if entry.read_to_string(&mut xml).is_ok() {
                let text = extract_pptx_slide_xml_text(&xml);
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    if !combined.is_empty() {
                        combined.push_str("\n\n");
                    }
                    combined.push_str(&format!("[สไลด์ {num}]\n{trimmed}"));
                }
            }
        }
    }

    Ok(cap_extracted_text(&combined, MAX_EXTRACTED_CHARS))
}

fn extract_spreadsheet_text(bytes: &[u8]) -> Result<String, String> {
    let mut workbook = open_workbook_auto_from_rs(Cursor::new(bytes))
        .map_err(|e| format!("ไม่สามารถเปิดไฟล์สเปรดชีตได้: {e}"))?;
    let sheet_names = workbook.sheet_names();
    if sheet_names.is_empty() {
        return Ok(String::new());
    }

    let mut sections: Vec<String> = Vec::new();
    for sheet_name in sheet_names.into_iter().take(MAX_SPREADSHEET_SHEETS) {
        if let Ok(range) = workbook.worksheet_range(&sheet_name) {
            let total_rows = range.height();
            let mut lines = vec![format!("[ชีต: {sheet_name}]")];
            let mut rendered_rows = 0usize;

            for row in range.rows().take(MAX_SPREADSHEET_ROWS_PER_SHEET) {
                let mut cells: Vec<String> = row
                    .iter()
                    .map(|cell| cell.to_string().trim().to_string())
                    .collect();
                while cells.last().is_some_and(|c| c.is_empty()) {
                    cells.pop();
                }
                if cells.iter().all(|c| c.is_empty()) {
                    continue;
                }
                lines.push(cells.join(" | "));
                rendered_rows += 1;
            }

            if total_rows > MAX_SPREADSHEET_ROWS_PER_SHEET {
                lines.push(format!(
                    "...[แสดงเฉพาะ {MAX_SPREADSHEET_ROWS_PER_SHEET} แถวแรกจากทั้งหมด {total_rows} แถว]..."
                ));
            }
            if rendered_rows > 0 {
                sections.push(lines.join("\n"));
            }
        }
    }

    Ok(cap_extracted_text(&sections.join("\n\n"), MAX_EXTRACTED_CHARS))
}

pub fn extract_document_text_sync(
    bytes: &[u8],
    mime_type: &str,
    file_name: &str,
) -> Result<String, String> {
    if bytes.len() > MAX_DOCUMENT_DOWNLOAD_BYTES {
        return Err("ไฟล์เอกสารมีขนาดใหญ่เกิน 20 MB เกินขีดจำกัดสำหรับให้ AI อ่าน".to_string());
    }
    let Some(format) = detect_document_format(mime_type, file_name) else {
        return Err(format!("ไม่รองรับการแยกข้อความจากไฟล์ '{file_name}'"));
    };

    match format {
        DocumentFormat::Pdf => extract_pdf_text(bytes),
        DocumentFormat::Docx => extract_docx_text(bytes),
        DocumentFormat::Pptx => extract_pptx_text(bytes),
        DocumentFormat::Spreadsheet => extract_spreadsheet_text(bytes),
        DocumentFormat::PlainText => Ok(cap_extracted_text(
            &decode_plain_text(bytes),
            MAX_EXTRACTED_CHARS,
        )),
    }
}

pub async fn extract_document_text(
    bytes: Vec<u8>,
    mime_type: String,
    file_name: String,
) -> Result<String, String> {
    tokio::task::spawn_blocking(move || extract_document_text_sync(&bytes, &mime_type, &file_name))
        .await
        .map_err(|e| format!("เกิดข้อผิดพลาดระหว่างแยกข้อความเอกสาร: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn make_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut cursor);
            let options = SimpleFileOptions::default();
            for (name, content) in entries {
                writer.start_file(*name, options).unwrap();
                writer.write_all(content).unwrap();
            }
            writer.finish().unwrap();
        }
        cursor.into_inner()
    }

    fn build_minimal_pdf(text: &str) -> Vec<u8> {
        let stream = format!("BT\n/F1 12 Tf\n72 720 Td\n({text}) Tj\nET\n");
        let mut pdf = Vec::new();
        pdf.extend_from_slice(b"%PDF-1.4\n");

        let mut offsets = Vec::new();
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".to_string(),
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n".to_string(),
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n".to_string(),
            format!(
                "4 0 obj\n<< /Length {} >>\nstream\n{}endstream\nendobj\n",
                stream.len(),
                stream
            ),
            "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n".to_string(),
        ];

        for obj in &objects {
            offsets.push(pdf.len());
            pdf.extend_from_slice(obj.as_bytes());
        }

        let xref_pos = pdf.len();
        pdf.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes());
        for off in offsets {
            pdf.extend_from_slice(format!("{off:010} 00000 n \n").as_bytes());
        }
        pdf.extend_from_slice(
            format!(
                "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n",
                objects.len() + 1
            )
            .as_bytes(),
        );
        pdf
    }

    #[test]
    fn classifies_images_documents_and_unsupported_accurately() {
        assert_eq!(classify_attachment("image/png", "photo.png"), AttachmentKind::Image);
        assert_eq!(classify_attachment("application/octet-stream", "slip.JPG"), AttachmentKind::Image);
        assert_eq!(classify_attachment("image/webp", "pic.webp"), AttachmentKind::Image);
        assert_eq!(classify_attachment("application/pdf", "invoice.pdf"), AttachmentKind::Document);
        assert_eq!(classify_attachment("application/octet-stream", "plan.docx"), AttachmentKind::Document);
        assert_eq!(classify_attachment("application/octet-stream", "budget.xlsx"), AttachmentKind::Document);
        assert_eq!(classify_attachment("application/octet-stream", "deck.pptx"), AttachmentKind::Document);
        assert_eq!(classify_attachment("text/csv; charset=utf-8", "sales.csv"), AttachmentKind::Document);
        assert_eq!(classify_attachment("audio/webm", "voice.webm"), AttachmentKind::Unsupported);
        assert_eq!(classify_attachment("application/octet-stream", "archive.bin"), AttachmentKind::Unsupported);
    }

    #[test]
    fn extracts_txt_and_csv_with_bom_and_caps_long_text() {
        let mut raw = vec![0xEF, 0xBB, 0xBF];
        raw.extend_from_slice("รายการ,ราคา\nชาไทย,45\nกาแฟดำ,55\n".as_bytes());
        let csv = extract_document_text_sync(&raw, "text/csv", "menu.csv").unwrap();
        assert!(csv.starts_with("รายการ,ราคา"));
        assert!(csv.contains("ชาไทย,45"));

        let long_text = "ก".repeat(MAX_EXTRACTED_CHARS + 500);
        let capped = cap_extracted_text(&long_text, MAX_EXTRACTED_CHARS);
        assert!(capped.contains("...[ตัดข้อความบางส่วน]..."));
    }

    #[test]
    fn extracts_docx_paragraphs_headers_and_tables() {
        let header_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:p><w:r><w:t>หัวกระดาษทริปเชียงใหม่</w:t></w:r></w:p>
</w:hdr>"#
            .as_bytes();
        let doc_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>กำหนดการเดินทางวันเสาร์</w:t></w:r></w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>เวลา</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>กิจกรรม</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>09:00</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>แวะคาเฟ่</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>"#
            .as_bytes();
        let bytes = make_zip(&[
            ("word/header1.xml", header_xml),
            ("word/document.xml", doc_xml),
        ]);
        let extracted = extract_document_text_sync(
            &bytes,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "trip.docx",
        )
        .unwrap();
        assert!(extracted.contains("หัวกระดาษทริปเชียงใหม่"));
        assert!(extracted.contains("กำหนดการเดินทางวันเสาร์"));
        assert!(extracted.contains("เวลา | กิจกรรม"));
        assert!(extracted.contains("09:00 | แวะคาเฟ่"));
    }

    #[test]
    fn extracts_pptx_slides_sorted_numerically() {
        let slide10 = r#"<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>สรุปท้ายสไลด์สิบ</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
</p:sld>"#
            .as_bytes();
        let slide2 = r#"<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>รายละเอียดสไลด์สอง</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
</p:sld>"#
            .as_bytes();
        let bytes = make_zip(&[
            ("ppt/slides/slide10.xml", slide10),
            ("ppt/slides/slide2.xml", slide2),
        ]);
        let extracted = extract_document_text_sync(
            &bytes,
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "pitch.pptx",
        )
        .unwrap();
        let pos2 = extracted.find("[สไลด์ 2]").unwrap();
        let pos10 = extracted.find("[สไลด์ 10]").unwrap();
        assert!(pos2 < pos10, "slide 2 must come before slide 10");
        assert!(extracted.contains("รายละเอียดสไลด์สอง"));
        assert!(extracted.contains("สรุปท้ายสไลด์สิบ"));
    }

    #[test]
    fn extracts_xlsx_spreadsheet_sheets_and_rows() {
        let content_types = r#"<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>"#
            .as_bytes();
        let root_rels = r#"<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"#
            .as_bytes();
        let workbook = r#"<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="ค่าใช้จ่ายทริป" sheetId="1" r:id="rId1"/></sheets>
</workbook>"#
            .as_bytes();
        let wb_rels = r#"<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>"#
            .as_bytes();
        let sheet1 = r#"<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1">
      <c r="A1" t="inlineStr"><is><t>รายการ</t></is></c>
      <c r="B1" t="inlineStr"><is><t>บาท</t></is></c>
    </row>
    <row r="2">
      <c r="A2" t="inlineStr"><is><t>ค่าโรงแรม</t></is></c>
      <c r="B2"><v>2400</v></c>
    </row>
  </sheetData>
</worksheet>"#
            .as_bytes();
        let bytes = make_zip(&[
            ("[Content_Types].xml", content_types),
            ("_rels/.rels", root_rels),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", wb_rels),
            ("xl/worksheets/sheet1.xml", sheet1),
        ]);
        let extracted = extract_document_text_sync(
            &bytes,
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "budget.xlsx",
        )
        .unwrap();
        assert!(extracted.contains("[ชีต: ค่าใช้จ่ายทริป]"));
        assert!(extracted.contains("รายการ | บาท"));
        assert!(extracted.contains("ค่าโรงแรม | 2400"));
    }

    #[test]
    fn extracts_minimal_pdf_and_handles_corrupt_pdf_without_panicking() {
        let valid_pdf = build_minimal_pdf("Hello BC Ai Chat 2026");
        let extracted =
            extract_document_text_sync(&valid_pdf, "application/pdf", "hello.pdf").unwrap();
        assert!(extracted.contains("Hello BC Ai Chat 2026"), "got: {extracted}");

        let corrupt = b"%PDF-1.4\n<<<not a real pdf binary>>>\x00\xFF";
        let res = extract_document_text_sync(corrupt, "application/pdf", "broken.pdf");
        assert!(res.is_err(), "corrupt pdf must return clean Err without panic");
    }
}
