use quick_xml::events::Event;
use quick_xml::Reader;
use regex::Regex;
use std::sync::OnceLock;

#[derive(Clone)]
enum XmlNode {
    Element(XmlElem),
    Text(String),
}

#[derive(Clone)]
struct XmlElem {
    name: String,
    attributes: Vec<(String, String)>,
    children: Vec<XmlNode>,
}

fn local_name(name: &str) -> &str {
    name.rsplit_once(':')
        .map(|(_, local)| local)
        .unwrap_or(name)
}

fn prefixed(parent: &str, local: &str) -> String {
    match parent.split_once(':') {
        Some((prefix, _)) => format!("{prefix}:{local}"),
        None => local.to_string(),
    }
}

fn parse_xml(text: &str) -> Result<XmlElem, String> {
    let text = text.trim_start_matches('\u{feff}');
    let mut reader = Reader::from_str(text);
    reader.config_mut().trim_text(false);
    let mut buf = Vec::new();
    let mut stack: Vec<XmlElem> = Vec::new();
    let mut root: Option<XmlElem> = None;

    loop {
        let event = reader
            .read_event_into(&mut buf)
            .map_err(|err| format!("Cannot parse XML: {err}"))?;
        match event {
            Event::Start(element) => {
                stack.push(read_element(&element)?);
            }
            Event::Empty(element) => {
                let parsed = read_element(&element)?;
                attach(&mut stack, &mut root, parsed)?;
            }
            Event::Text(text) => {
                let value = text
                    .unescape()
                    .map_err(|err| format!("Cannot parse XML text: {err}"))?
                    .into_owned();
                if !value.trim().is_empty() {
                    if let Some(parent) = stack.last_mut() {
                        parent
                            .children
                            .push(XmlNode::Text(value.trim().to_string()));
                    }
                }
            }
            Event::CData(text) => {
                let value = String::from_utf8_lossy(&text).into_owned();
                if let Some(parent) = stack.last_mut() {
                    parent.children.push(XmlNode::Text(value));
                }
            }
            Event::End(_) => {
                let finished = stack.pop().ok_or("XML end tag has no matching start")?;
                attach(&mut stack, &mut root, finished)?;
            }
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }
    root.ok_or_else(|| "XML document has no root element".to_string())
}

fn read_element(element: &quick_xml::events::BytesStart<'_>) -> Result<XmlElem, String> {
    let name = String::from_utf8_lossy(element.name().as_ref()).into_owned();
    let mut attributes = Vec::new();
    for attribute in element.attributes() {
        let attribute = attribute.map_err(|err| format!("Cannot parse XML attribute: {err}"))?;
        let key = String::from_utf8_lossy(attribute.key.as_ref()).into_owned();
        let value = attribute
            .unescape_value()
            .map_err(|err| format!("Cannot parse XML attribute: {err}"))?
            .into_owned();
        attributes.push((key, value));
    }
    Ok(XmlElem {
        name,
        attributes,
        children: Vec::new(),
    })
}

fn attach(
    stack: &mut Vec<XmlElem>,
    root: &mut Option<XmlElem>,
    element: XmlElem,
) -> Result<(), String> {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(XmlNode::Element(element));
        Ok(())
    } else if root.is_none() {
        *root = Some(element);
        Ok(())
    } else {
        Err("XML document has more than one root element".to_string())
    }
}

fn child_mut<'a>(element: &'a mut XmlElem, name: &str) -> Option<&'a mut XmlElem> {
    element.children.iter_mut().find_map(|node| match node {
        XmlNode::Element(child) if local_name(&child.name) == name => Some(child),
        _ => None,
    })
}

fn ensure_child<'a>(element: &'a mut XmlElem, name: &str) -> &'a mut XmlElem {
    if child_mut(element, name).is_none() {
        let child_name = prefixed(&element.name, name);
        element.children.push(XmlNode::Element(XmlElem {
            name: child_name,
            attributes: Vec::new(),
            children: Vec::new(),
        }));
    }
    child_mut(element, name).expect("child was just inserted")
}

fn write_xml(element: &XmlElem) -> String {
    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    write_element(&mut out, element, 0);
    out.push('\n');
    out
}

fn write_element(out: &mut String, element: &XmlElem, depth: usize) {
    let indent = "  ".repeat(depth);
    out.push_str(&indent);
    out.push('<');
    out.push_str(&element.name);
    for (key, value) in &element.attributes {
        out.push(' ');
        out.push_str(key);
        out.push_str("=\"");
        out.push_str(&escape_attr(value));
        out.push('"');
    }
    if element.children.is_empty() {
        out.push_str("/>\n");
        return;
    }
    let text_only = element
        .children
        .iter()
        .all(|node| matches!(node, XmlNode::Text(_)));
    if text_only {
        out.push('>');
        for node in &element.children {
            if let XmlNode::Text(text) = node {
                out.push_str(&escape_text(text));
            }
        }
        out.push_str("</");
        out.push_str(&element.name);
        out.push_str(">\n");
        return;
    }
    out.push_str(">\n");
    for node in &element.children {
        match node {
            XmlNode::Element(child) => write_element(out, child, depth + 1),
            XmlNode::Text(text) => {
                out.push_str(&"  ".repeat(depth + 1));
                out.push_str(&escape_text(text));
                out.push('\n');
            }
        }
    }
    out.push_str(&indent);
    out.push_str("</");
    out.push_str(&element.name);
    out.push_str(">\n");
}

fn escape_text(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn escape_attr(value: &str) -> String {
    escape_text(value).replace('"', "&quot;")
}

pub fn xml_escape(value: &str) -> String {
    escape_text(value)
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn java_prefix_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^src/(main|test)/java/").unwrap())
}

pub fn relative_java_path(path: &str) -> String {
    java_prefix_re()
        .replace(&path.replace('\\', "/"), "")
        .to_string()
}

pub fn class_name(path: &str) -> String {
    let relative = relative_java_path(path);
    let without_ext = relative.strip_suffix(".java").unwrap_or(&relative);
    without_ext.replace('/', ".")
}

pub fn inject_plugins(pom: &str, snippet: &str) -> Result<String, String> {
    let mut document = parse_xml(pom)?;
    if local_name(&document.name) != "project" {
        return Err("pom.xml root element is not project".to_string());
    }
    let wrapped = format!("<plugins>{snippet}</plugins>");
    let additions = parse_xml(&wrapped)?;
    let build = ensure_child(&mut document, "build");
    let plugins = ensure_child(build, "plugins");
    for node in additions.children {
        if let XmlNode::Element(element) = node {
            plugins.children.push(XmlNode::Element(element));
        }
    }
    Ok(write_xml(&document))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_plugins_to_the_main_build_not_a_profile() {
        let pom = "<project xmlns=\"http://maven.apache.org/POM/4.0.0\"><profiles><profile><id>other</id><build><plugins/></build></profile></profiles></project>";
        let snippet = "<plugin><artifactId>maven-checkstyle-plugin</artifactId></plugin><plugin><artifactId>spotbugs-maven-plugin</artifactId></plugin>";
        let written = inject_plugins(pom, snippet).unwrap();
        assert!(written.contains("maven-checkstyle-plugin"));
        assert!(written.contains("spotbugs-maven-plugin"));
        let parsed = parse_xml(&written).unwrap();
        let build = child_mut_ref(&parsed, "build").unwrap();
        let plugins = child_mut_ref(build, "plugins").unwrap();
        let count = plugins
            .children
            .iter()
            .filter(|node| matches!(node, XmlNode::Element(element) if local_name(&element.name) == "plugin"))
            .count();
        assert_eq!(count, 2);
    }

    fn child_mut_ref<'a>(element: &'a XmlElem, name: &str) -> Option<&'a XmlElem> {
        element.children.iter().find_map(|node| match node {
            XmlNode::Element(child) if local_name(&child.name) == name => Some(child),
            _ => None,
        })
    }

    #[test]
    fn creates_the_build_block_and_keeps_staged_selectors() {
        let pom = "<project/>";
        let snippet = "<plugin><includes>demo/Example.java</includes><onlyAnalyze>demo.Example,demo.Example$[^/]*</onlyAnalyze></plugin>";
        let written = inject_plugins(pom, snippet).unwrap();
        assert!(written.contains("<includes>demo/Example.java</includes>"));
        assert!(written.contains("<onlyAnalyze>demo.Example,demo.Example$[^/]*</onlyAnalyze>"));
    }

    #[test]
    fn class_names_cover_nested_classes() {
        assert_eq!(
            class_name("src/main/java/demo/Example.java"),
            "demo.Example"
        );
        assert_eq!(
            relative_java_path("src/test/java/demo/Example.java"),
            "demo/Example.java"
        );
    }
}
