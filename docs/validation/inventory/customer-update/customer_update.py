#!/usr/bin/env python3
"""On-demand, offline customer-update draft. Structured task input; never sends mail."""
import json, re, sys
from email.message import EmailMessage
from pathlib import Path

def clean(value):
    if not isinstance(value, str):
        raise ValueError("Textfeld fehlt oder hat den falschen Typ")
    value = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[E-Mail]", value)
    value = re.sub(r"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b", "[IBAN]", value)
    return value.strip()

def draft(data):
    if not isinstance(data, dict): raise ValueError("JSON-Objekt erforderlich")
    project = clean(data.get("project", ""))
    if not project or not isinstance(data.get("tasks"), list):
        raise ValueError("Projektname und strukturierte Aufgabenliste erforderlich")
    grouped = {"done": [], "open": [], "next": []}
    seen = {}
    for task in data["tasks"]:
        if not isinstance(task, dict): raise ValueError("Aufgabe muss ein Objekt sein")
        identifier, status, title = task.get("id"), task.get("status"), clean(task.get("title", ""))
        if not isinstance(identifier, str) or not identifier or status not in grouped or not title:
            raise ValueError("Aufgabe braucht ID, Titel und Status done/open/next")
        if identifier in seen:
            if seen[identifier] != task: raise ValueError("Widersprüchliche Aufgabe: " + identifier)
            continue
        seen[identifier] = task
        # Treat all text as literal data. No LLM, eval, execution or external call.
        grouped[status].append(title)
    if not grouped["done"]: raise ValueError("Keine erledigten Aufgaben; Zeitraum und Inhalt bitte menschlich klären")
    sections = ["Betreff: Projektstand – " + project, "", "Hallo,", "", "hier ist der aktuelle Stand aus unserer Aufgabenliste:"]
    for status,label in [("done","Erledigt"),("open","Offen"),("next","Nächste Schritte")]:
        sections += ["", label + ":"]
        sections += ["- " + value.replace("\n", " ") for value in grouped[status]] or ["- Keine Angaben in der Aufgabenliste."]
    sections += ["", "Dieser Entwurf wird vor dem Versand persönlich geprüft."]
    return {"subject": "Projektstand – " + project,"body": "\n".join(sections),"status": "draft", "requires_human_review": True,"sent": False}

def main():
    if len(sys.argv) != 3: raise SystemExit("Aufruf: customer_update.py input.json draft.json")
    output = Path(sys.argv[2])
    try: result = draft(json.loads(Path(sys.argv[1]).read_text()))
    except (ValueError,TypeError,OSError) as error: result = {"status":"needs_input","error":str(error),"sent":False,"requires_human_review":True}
    # A failed rerun must never leave a previous sendable draft behind.
    output.with_suffix(".eml").unlink(missing_ok=True)
    if result["status"] == "draft":
        message = EmailMessage()
        message["Subject"] = result["subject"].replace("\n", " ").replace("\r", " ")
        message["X-Unsent"] = "1"
        message.set_content(result["body"])
        output.with_suffix(".eml").write_bytes(bytes(message))
        result["email_file"] = output.with_suffix(".eml").name
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")

if __name__ == "__main__": main()
