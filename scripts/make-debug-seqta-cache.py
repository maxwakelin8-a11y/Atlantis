#!/usr/bin/env python3
"""Writes a made-up SEQTA cache for screenshots: `scripts/make-debug-seqta-cache.py /tmp/seqta-debug`,
then `Atlantis -debugSeqtaCache /tmp/seqta-debug -debugPage subjects`. All names and marks are invented."""
import json, os, sys
from datetime import datetime, timedelta, timezone

root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/seqta-debug"
os.makedirs(root + "/message-bodies", exist_ok=True)
now = datetime.now(timezone.utc).replace(microsecond=0)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
day = lambda n: (datetime.now() + timedelta(days=n)).strftime("%Y-%m-%d")

def save(name, items):
    with open(f"{root}/{name}.json", "w") as f:
        json.dump({"version": 1, "syncedAt": iso(now), "items": items}, f, indent=1)

subjects = [
    dict(code="ENGG9", name="English 9", colour="#3b82f6", teacher="Ms Example", programme=1, metaclass=11),
    dict(code="MATH9", name="Mathematics 9", colour="#22c55e", teacher="Mr Sample", programme=2, metaclass=12),
    dict(code="SCIE9", name="Science 9", colour="#f97316", teacher="Dr Placeholder", programme=3, metaclass=13),
    dict(code="HIST9", name="History 9", colour="#a855f7", teacher="Mrs Imaginary", programme=4, metaclass=14),
]
def a(i, title, subj, due, status, marks=None, details=None):
    s = next(x for x in subjects if x["code"] == subj)
    d = dict(id=i, title=title, subject=s["name"], code=subj, due=day(due), status=status,
             submitted=status != "PENDING", programme=s["programme"], metaclass=s["metaclass"])
    if marks: d["marks"] = marks
    if details: d["details"] = details
    return d
assessments = [
    a(1, "Persuasive speech", "ENGG9", 6, "PENDING", details="Write and deliver a 3 minute speech on a topic you care about."),
    a(2, "Short story draft", "ENGG9", -12, "MARKS_RELEASED", dict(grade="B", percentage=74, feedback="Strong opening and good dialogue. Work on the ending: it felt rushed.")),
    a(3, "Poetry analysis", "ENGG9", -30, "MARKS_RELEASED", dict(grade="A", percentage=88, feedback="Insightful reading of the imagery.")),
    a(4, "Algebra test", "MATH9", 3, "PENDING"),
    a(5, "Statistics project", "MATH9", -9, "MARKS_RELEASED", dict(grade="B", percentage=71.5)),
    a(6, "Lab report: reactions", "SCIE9", 10, "PENDING"),
    a(7, "Cells quiz", "SCIE9", -20, "OVERDUE"),
    a(8, "Source analysis", "HIST9", 14, "PENDING"),
]
files = [
    dict(subjectCode="ENGG9", name="Term 4 course outline.pdf", uuid="11111111-1111-1111-1111-111111111111", size=182000, source="Course outline"),
    dict(subjectCode="ENGG9", name="Speech rubric.docx", uuid="22222222-2222-2222-2222-222222222222", size=45000, source="Lesson 2026-11-04 · Persuasive writing"),
    dict(subjectCode="MATH9", name="Algebra revision sheet.pdf", uuid="33333333-3333-3333-3333-333333333333", size=310000, source="Course outline"),
]
msgs = [
    (8101, 0, "Ms Example", "staff", 246, "Excursion form", False, 1),
    (8102, 3, "Mr Sample", "staff", 247, "Maths test on Thursday", False, 0),
    (8103, 26, "Student Services", "staff", 250, "Library books due back", True, 0),
    (8104, 80, "Dr Placeholder", "staff", 252, "Science lab groups", True, 0),
]
messages = [dict(id=i, date=iso(now - timedelta(hours=h)), sender=s, senderType=t, senderID=sid, subject=sub, read=r, attachmentCount=ac)
            for i, h, s, t, sid, sub, r, ac in msgs]
save("subjects", subjects); save("assessments", assessments); save("files", files); save("messages", messages)
with open(root + "/meta.json", "w") as f:
    json.dump({"version": 1, "lastSync": iso(now), "lastReason": "manual", "kinds": {}, "failures": {}, "newMarkAssessmentIDs": []}, f)
body = "Hi,\n\nPlease bring the signed excursion form to the front office by Friday.\nLet me know if you have any questions.\n\nThanks,\nMs Example"
with open(root + "/message-bodies/8101.json", "w") as f:
    json.dump(dict(summary=messages[0], recipients=["Example Student"], body=body,
                   files=[dict(name="Excursion form.pdf", uuid="44444444-4444-4444-4444-444444444444")]), f)
print("wrote", root)
