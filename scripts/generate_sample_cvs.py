"""Generate 5 synthetic CVs. Each one deliberately exercises an edge case."""
import sys, os
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas
from docx import Document

OUT = sys.argv[1]

CVS = {
 "Sara_Haddad_CV.pdf": """Sara Haddad
Senior Salesforce Developer
sara.haddad@example.com | +961 70 123 456 | Beirut, Lebanon

SUMMARY
Salesforce developer with 8 years of experience building scalable Apex and LWC solutions for B2B SaaS clients.

EXPERIENCE
Senior Salesforce Developer | Nimbus Cloud Solutions | Mar 2021 - Present
- Led the design of an event-driven order sync using Platform Events and REST APIs.
- Built 30+ Lightning Web Components for the sales console.
- Introduced CI/CD with Git and scratch orgs, cutting release time by 40%.
- Prototyped an Agentforce agent for case triage.
Salesforce Developer | BrightPath Consulting | Jun 2018 - Feb 2021
- Developed Apex triggers, batch jobs and SOQL-optimised services for 12 client orgs.
- Automated onboarding with Salesforce Flow.

EDUCATION
BSc Computer Science | American University of Beirut | 2018

SKILLS
Apex, LWC, SOQL, Salesforce Flow, REST APIs, Platform Events, Git, CI/CD, Agentforce

CERTIFICATIONS
Salesforce Platform Developer I (2019)
Salesforce Platform Developer II (2022)
Salesforce Agentforce Specialist (2025)
""",
 "Omar_Khalil_CV.docx": """Omar Khalil
Full Stack Developer
omar.khalil@example.com | +962 79 555 0101 | Amman, Jordan

SUMMARY
Full stack engineer with 12+ years of experience across web platforms and CRM integrations.

EXPERIENCE
Full Stack Developer | Zenith Apps | Jan 2022 - Present
- Built Lightning Web Components for a client's Salesforce org and connected them to a Node.js backend.
- Designed PostgreSQL schemas for a multi-tenant SaaS product.
Frontend Developer | PixelForge | Jun 2019 - Mar 2022
- Delivered React and TypeScript single-page apps for e-commerce clients.
Junior Web Developer | CodeNest | 2018 - 2019
- Maintained PHP and jQuery websites.

EDUCATION
BEng Software Engineering | University of Jordan

SKILLS
JavaScript, React, Node.js, TypeScript, PostgreSQL, Salesforce Administration

Contact: omar.k.dev@gmail.com
""",
 "Lina_Mansour_CV.pdf": """Lina Mansour
Salesforce Administrator
Amman, Jordan

SUMMARY
Detail-oriented Salesforce administrator focused on automation and reporting.

EXPERIENCE
Salesforce Administrator | Orbit Retail Group | Present
- Maintain users, profiles and permission sets for 250 users.
- Built Salesforce Flow automations replacing legacy workflow rules.
- Create Reports and Dashboards for regional sales managers.
CRM Intern | Orbit Retail Group | Jun 2023 - Dec 2023
- Cleaned and imported 40,000 records using Data Loader.

EDUCATION
BA Business Information Systems | Princess Sumaya University for Technology

SKILLS
Salesforce Flow, Reports and Dashboards, Data Loader, Excel

CERTIFICATIONS
Salesforce Certified Administrator (2024)
""",
 "Daniel_Reyes_CV.docx": """Daniel Reyes
Salesforce Technical Architect
daniel.reyes@example.com | +1 415 555 0199 | Austin, USA

SUMMARY
Technical architect with over 12 years of experience designing enterprise Salesforce and Java platforms.

EXPERIENCE
Salesforce Technical Architect | Vertex Global | Aug 2020 - Present
- Own the integration architecture for 3 Salesforce orgs using MuleSoft and REST APIs.
- Mentored a team of 8 developers on Apex design patterns and code review.
Lead Salesforce Developer | Harbor Systems | Jan 2015 - Dec 2018
- Built Apex services, SOQL-heavy batch jobs and Visualforce pages.
- Migrated Aura components to LWC.
Java Developer | Sunline Tech | Jul 2012 - Dec 2014
- Developed Java Spring microservices.

EDUCATION
MSc Software Engineering | University of Texas at Austin | 2012

SKILLS
Apex, LWC, SOQL, Integration Architecture, MuleSoft, Java, Data Modeling

CERTIFICATIONS
Salesforce Application Architect (2021)
Salesforce Platform Developer II (2016)
Salesforce Platform Developer II (2019)
""",
 "Priya_Nair_CV.pdf": """Priya Nair
Data Analyst
priya.nair@example.com | +44 7700 900123 | London, UK

SUMMARY
Data analyst with 5 years of experience turning raw data into decisions.

EXPERIENCE
Data Analyst | Meridian Health | Feb 2021 - Present
- Built CRM Analytics dashboards on top of Salesforce data for the sales team.
- Automated reporting pipelines in Python and SQL.
BI Intern | Quantica | Jun 2020 - Dec 2020
- Produced Tableau reports for marketing.

EDUCATION
MSc Data Science | University of Edinburgh | 2020

SKILLS
SQL, Python, Tableau, Excel, Power BI
""",
}

def write_pdf(path, text):
    # pageCompression=0 keeps content streams plain-text (see README: PDF extraction)
    c = canvas.Canvas(path, pagesize=A4, pageCompression=0)
    w, h = A4
    y = h - 50
    for line in text.splitlines():
        if y < 50:
            c.showPage(); y = h - 50
        is_header = line.isupper() and line.strip() != ""
        c.setFont("Helvetica-Bold" if is_header else "Helvetica", 11 if is_header else 10)
        c.drawString(50, y, line)
        y -= 18 if is_header else 14
    c.save()

def write_docx(path, text):
    d = Document()
    for line in text.splitlines():
        p = d.add_paragraph(line)
        if line.isupper() and line.strip():
            p.runs[0].bold = True
    d.save(path)

os.makedirs(OUT, exist_ok=True)
for name, text in CVS.items():
    p = os.path.join(OUT, name)
    (write_pdf if name.endswith(".pdf") else write_docx)(p, text)
    print("wrote", p)
