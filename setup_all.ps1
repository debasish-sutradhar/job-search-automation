# setup_all.ps1
# Creates project folders and files for Job Search Automation (Windows)
$ErrorActionPreference = 'Stop'
Write-Host "Creating Job Search Automation project files..." -ForegroundColor Green

# Create directories
$dirs = @('utils','notifications','scrapers','dashboard\templates','.github\workflows')
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# utils/__init__.py
@"
# Utils package
"@ | Out-File -FilePath "utils\__init__.py" -Encoding UTF8

# utils/config.py
@"
import os
from dotenv import load_dotenv

load_dotenv()

# Google Sheets
SHEET_ID = os.getenv('SHEET_ID')
CONFIG_SHEET_ID = os.getenv('CONFIG_SHEET_ID')
GOOGLE_CREDS_PATH = 'credentials.json'

# Twilio WhatsApp
TWILIO_ACCOUNT_SID = os.getenv('TWILIO_ACCOUNT_SID')
TWILIO_AUTH_TOKEN = os.getenv('TWILIO_AUTH_TOKEN')
TWILIO_WHATSAPP_FROM = os.getenv('TWILIO_WHATSAPP_FROM', 'whatsapp:+14155238886')
WHATSAPP_TO = os.getenv('WHATSAPP_TO', 'whatsapp:+16729654350')

# Job Search
LOCATION = os.getenv('LOCATION', 'Vancouver, BC')
KEYWORDS = os.getenv('KEYWORDS', 'IT Support,Deskside Technician,Cybersecurity Analyst').split(',')

# Flask
FLASK_SECRET_KEY = os.getenv('FLASK_SECRET_KEY', 'dev-key-change-in-prod')
DASHBOARD_PORT = int(os.getenv('DASHBOARD_PORT', 5000))

# Database
DB_PATH = 'jobs.db'
"@ | Out-File -FilePath "utils\config.py" -Encoding UTF8

# utils/deduplicator.py
@"
from difflib import SequenceMatcher

def is_duplicate(new_job, existing_jobs):
    for existing in existing_jobs:
        if new_job['url'] == existing.get('url'):
            return True
        
        title_sim = SequenceMatcher(
            None, new_job['title'].lower(), existing.get('title', '').lower()
        ).ratio()
        
        company_sim = SequenceMatcher(
            None, new_job['company'].lower(), existing.get('company', '').lower()
        ).ratio()
        
        if title_sim > 0.90 and company_sim > 0.85:
            return True
    
    return False
"@ | Out-File -FilePath "utils\deduplicator.py" -Encoding UTF8

# utils/database.py
@"
import sqlite3
import gspread
from oauth2client.service_account import ServiceAccountCredentials
from datetime import datetime
import hashlib
from utils.config import SHEET_ID, GOOGLE_CREDS_PATH, DB_PATH

class JobDatabase:
    def __init__(self):
        self.conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        self.create_tables()
        self.sheet = self.get_sheet()
    
    def create_tables(self):
        cursor = self.conn.cursor()
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY,
                date_found TEXT,
                company TEXT,
                title TEXT,
                location TEXT,
                job_type TEXT,
                source TEXT,
                url TEXT UNIQUE,
                status TEXT DEFAULT 'New',
                date_applied TEXT,
                notes TEXT,
                recruiter_contact TEXT,
                description TEXT,
                salary TEXT,
                relevance_score INTEGER DEFAULT 50,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        self.conn.commit()
    
    def get_sheet(self):
        try:
            scope = ["https://spreadsheets.google.com/feeds", 
                     "https://www.googleapis.com/auth/drive"]
            creds = ServiceAccountCredentials.from_json_keyfile_name(
                GOOGLE_CREDS_PATH, scope
            )
            client = gspread.authorize(creds)
            return client.open_by_key(SHEET_ID).sheet1
        except Exception as e:
            print(f"⚠️  Google Sheets: {e}")
            return None
    
    def generate_job_id(self, company, title, url):
        return hashlib.md5(f"{company}{title}{url}".encode()).hexdigest()[:12]
    
    def add_job(self, job_data):
        job_id = self.generate_job_id(
            job_data['company'], job_data['title'], job_data['url']
        )
        
        cursor = self.conn.cursor()
        cursor.execute("SELECT job_id FROM jobs WHERE job_id = ?", (job_id,))
        if cursor.fetchone():
            return False
        
        cursor.execute('''
            INSERT INTO jobs (
                job_id, date_found, company, title, location, 
                job_type, source, url, description, salary, relevance_score
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            job_id, datetime.now().strftime('%Y-%m-%d'),
            job_data.get('company', ''), job_data.get('title', ''),
            job_data.get('location', ''), job_data.get('job_type', 'Full-time'),
            job_data.get('source', ''), job_data.get('url', ''),
            job_data.get('description', '')[:500], job_data.get('salary', ''),
            job_data.get('relevance_score', 50)
        ))
        self.conn.commit()
        
        if self.sheet:
            try:
                self.sheet.append_row([
                    job_id, datetime.now().strftime('%Y-%m-%d'),
                    job_data.get('company', ''), job_data.get('title', ''),
                    job_data.get('location', ''), job_data.get('job_type', 'Full-time'),
                    job_data.get('source', ''), job_data.get('url', ''),
                    'New', '', '', '', job_data.get('relevance_score', 50)
                ])
            except:
                pass
        
        return True
    
    def get_all_jobs(self, status=None, limit=100):
        cursor = self.conn.cursor()
        if status:
            cursor.execute(
                "SELECT * FROM jobs WHERE status = ? ORDER BY relevance_score DESC, date_found DESC LIMIT ?",
                (status, limit)
            )
        else:
            cursor.execute(
                "SELECT * FROM jobs ORDER BY relevance_score DESC, date_found DESC LIMIT ?", (limit,)
            )
        
        columns = [desc[0] for desc in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]
    
    def update_status(self, job_id, status, notes=''):
        cursor = self.conn.cursor()
        date_applied = datetime.now().strftime('%Y-%m-%d') if status == 'Applied' else None
        cursor.execute('''
            UPDATE jobs SET status = ?, date_applied = ?, notes = ? WHERE job_id = ?
        ''', (status, date_applied, notes, job_id))
        self.conn.commit()
    
    def get_stats(self):
        cursor = self.conn.cursor()
        cursor.execute('SELECT status, COUNT(*) as count FROM jobs GROUP BY status')
        stats = dict(cursor.fetchall())
        cursor.execute("SELECT COUNT(*) FROM jobs")
        stats['total'] = cursor.fetchone()[0]
        return stats

db = JobDatabase()
"@ | Out-File -FilePath "utils\database.py" -Encoding UTF8

# config_manager.py
@"
\"\"\"Dynamic Configuration Manager - Reads settings from Google Sheet\"\"\"
import gspread
from oauth2client.service_account import ServiceAccountCredentials

class ConfigManager:
    def __init__(self, config_sheet_id):
        self.sheet_id = config_sheet_id
        self.config = self._load_config()
    
    def _load_config(self):
        try:
            scope = [\"https://spreadsheets.google.com/feeds\",
                     \"https://www.googleapis.com/auth/drive\"]
            creds = ServiceAccountCredentials.from_json_keyfile_name(
                'credentials.json', scope
            )
            client = gspread.authorize(creds)
            sheet = client.open_by_key(self.sheet_id).worksheet('Config')
            
            data = sheet.get_all_records()
            config = {}
            
            for row in data:
                setting = row.get('Setting', '')
                value = row.get('Value', '')
                
                if setting == 'Keywords':
                    config['keywords'] = [k.strip() for k in value.split(',')]
                elif setting == 'Location':
                    config['location'] = value
                elif setting == 'WhatsApp':
                    config['whatsapp'] = value
                elif setting == 'Email':
                    config['email'] = value
                elif setting == 'Alert Frequency':
                    config['alert_frequency'] = value
                elif setting == 'Job Sources':
                    config['job_sources'] = [s.strip() for s in value.split(',')]
                elif setting == 'Priority Keywords':
                    config['priority_keywords'] = [k.strip() for k in value.split(',')]
                elif setting == 'Follow-up Days':
                    config['followup_days'] = int(value)
            
            print(f\"✅ Config loaded: {len(config)} settings\")
            return config
            
        except Exception as e:
            print(f\"⚠️  Config load failed: {e}, using defaults\")
            return {
                'keywords': ['IT Support', 'Deskside Technician', 'Cybersecurity Analyst'],
                'location': 'Vancouver, BC',
                'whatsapp': '+16729654350',
                'email': 'debasish2211@gmail.com',
                'alert_frequency': 'Daily',
                'job_sources': ['Indeed', 'Job Bank'],
                'priority_keywords': ['CompTIA A+', 'CCNA', 'ISC2 CC', 'Cybersecurity'],
                'followup_days': 7
            }
    
    def reload(self):
        self.config = self._load_config()
        return self.config
    
    def get(self, key, default=None):
        return self.config.get(key, default)
"@ | Out-File -FilePath "config_manager.py" -Encoding UTF8

# smart_filter.py
@"
\"\"\"Smart Job Filter with Ranking\"\"\"
from datetime import datetime
from difflib import SequenceMatcher

class SmartFilter:
    def __init__(self, priority_keywords):
        self.priority_keywords = [k.lower() for k in priority_keywords]
    
    def calculate_relevance_score(self, job):
        score = 50
        
        title = job.get('title', '').lower()
        description = job.get('description', '').lower()
        combined_text = f\"{title} {description}\"
        
        # Boost for priority keywords
        for keyword in self.priority_keywords:
            if keyword in combined_text:
                score += 15
        
        # Entry-level boost
        entry_keywords = ['entry', 'junior', 'associate', 'level 1', 'tier 1']
        if any(k in combined_text for k in entry_keywords):
            score += 10
        
        # Salary boost
        if job.get('salary') and job['salary'].strip():
            score += 5
        
        # Recency boost
        try:
            date_found = datetime.strptime(job.get('date_found', ''), '%Y-%m-%d')
            days_old = (datetime.now() - date_found).days
            if days_old <= 1:
                score += 20
            elif days_old <= 3:
                score += 10
            elif days_old <= 7:
                score += 5
        except:
            pass
        
        return min(score, 100)
    
    def is_duplicate(self, new_job, existing_jobs):
        for existing in existing_jobs:
            if new_job['url'] == existing.get('url'):
                return True
            
            title_sim = SequenceMatcher(
                None, new_job['title'].lower(), existing.get('title', '').lower()
            ).ratio()
            
            company_sim = SequenceMatcher(
                None, new_job['company'].lower(), existing.get('company', '').lower()
            ).ratio()
            
            if title_sim > 0.90 and company_sim > 0.85:
                return True
        
        return False
    
    def filter_and_rank(self, jobs, existing_jobs):
        unique_jobs = []
        
        for job in jobs:
            if not self.is_duplicate(job, existing_jobs + unique_jobs):
                job['relevance_score'] = self.calculate_relevance_score(job)
                unique_jobs.append(job)
        
        unique_jobs.sort(key=lambda x: x['relevance_score'], reverse=True)
        return unique_jobs
"@ | Out-File -FilePath "smart_filter.py" -Encoding UTF8

# gmail_notifier.py
@"
\"\"\"Gmail API Notifier\"\"\"
import os
import base64
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
import pickle
from datetime import datetime

SCOPES = ['https://www.googleapis.com/auth/gmail.send']

class GmailNotifier:
    def __init__(self):
        self.service = self._get_gmail_service()
    
    def _get_gmail_service(self):
        creds = None
        
        if os.path.exists('token.pickle'):
            with open('token.pickle', 'rb') as token:
                creds = pickle.load(token)
        
        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                if os.path.exists('client_secret.json'):
                    flow = InstalledAppFlow.from_client_secrets_file(
                        'client_secret.json', SCOPES
                    )
                    creds = flow.run_local_server(port=0)
                else:
                    print(\"⚠️  Gmail: client_secret.json not found\")
                    return None
            
            with open('token.pickle', 'wb') as token:
                pickle.dump(creds, token)
        
        return build('gmail', 'v1', credentials=creds)
    
    def send_daily_alert(self, to_email, jobs, stats):
        if not self.service:
            print(\"⚠️  Gmail not configured\")
            return False
        
        html_content = self._build_daily_email_html(jobs, stats)
        
        message = MIMEMultipart('alternative')
        message['Subject'] = f\"🎯 {len(jobs)} New Job Opportunities - {datetime.now().strftime('%Y-%m-%d')}\"
        message['From'] = 'me'
        message['To'] = to_email
        
        html_part = MIMEText(html_content, 'html')
        message.attach(html_part)
        
        try:
            raw = base64.urlsafe_b64encode(message.as_bytes()).decode()
            body = {'raw': raw}
            
            self.service.users().messages().send(
                userId='me', body=body
            ).execute()
            
            print(f\"✅ Gmail sent to {to_email}\")
            return True
            
        except Exception as e:
            print(f\"❌ Gmail failed: {e}\")
            return False

gmail = GmailNotifier()
"@ | Out-File -FilePath "gmail_notifier.py" -Encoding UTF8

# notifications/__init__.py
@"
# Notifications package
"@ | Out-File -FilePath "notifications\__init__.py" -Encoding UTF8

# notifications/whatsapp_notifier.py
@"
\"\"\"WhatsApp Notifier via Twilio\"\"\"
from twilio.rest import Client
from datetime import datetime
from utils.config import TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_WHATSAPP_FROM, WHATSAPP_TO

class WhatsAppNotifier:
    def __init__(self):
        if TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN:
            self.client = Client(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
        else:
            self.client = None
            print(\"⚠️  WhatsApp not configured\")
    
    def send_message(self, message):
        if not self.client:
            print(\"⚠️  WhatsApp: Skipping (not configured)\")
            return False
        
        try:
            msg = self.client.messages.create(
                from_=TWILIO_WHATSAPP_FROM,
                body=message,
                to=WHATSAPP_TO
            )
            print(f\"✅ WhatsApp sent: {msg.sid}\")
            return True
        except Exception as e:
            print(f\"❌ WhatsApp failed: {e}\")
            return False

notifier = WhatsAppNotifier()
"@ | Out-File -FilePath "notifications\whatsapp_notifier.py" -Encoding UTF8

# scrapers/__init__.py
@"
# Scrapers package
"@ | Out-File -FilePath "scrapers\__init__.py" -Encoding UTF8

# scrapers/indeed_scraper.py
@"
\"\"\"Indeed Canada Scraper\"\"\"
import requests
from bs4 import BeautifulSoup
import time
from utils.config import KEYWORDS, LOCATION

def scrape_indeed(keywords=None, location=None):
    keywords = keywords or KEYWORDS
    location = location or LOCATION
    all_jobs = []
    
    for keyword in keywords:
        print(f\"  🔍 Indeed: '{keyword}'...\")
        url = f\"https://ca.indeed.com/jobs?q={keyword.replace(' ', '+')}&l={location.replace(' ', '+')}&radius=25&fromage=7\"
        
        try:
            response = requests.get(url, headers={'User-Agent': 'Mozilla/5.0'}, timeout=10)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            for card in soup.find_all('div', class_='job_seen_beacon', limit=10):
                try:
                    title_elem = card.find('h2', class_='jobTitle')
                    company_elem = card.find('span', class_='companyName')
                    link = title_elem.find('a') if title_elem else None
                    
                    if title_elem and company_elem and link:
                        all_jobs.append({
                            'company': company_elem.text.strip(),
                            'title': title_elem.text.strip(),
                            'location': location,
                            'source': 'Indeed',
                            'url': 'https://ca.indeed.com' + link['href'],
                            'job_type': 'Full-time',
                            'salary': '',
                            'description': ''
                        })
                except:
                    continue
            
            time.sleep(2)
        except Exception as e:
            print(f\"    ❌ {e}\")
    
    print(f\"  ✅ Indeed: {len(all_jobs)} jobs\")
    return all_jobs
"@ | Out-File -FilePath "scrapers\indeed_scraper.py" -Encoding UTF8

# scrapers/jobbank_scraper.py
@"
\"\"\"Job Bank Canada Scraper\"\"\"
import requests
from bs4 import BeautifulSoup
import time
from utils.config import KEYWORDS, LOCATION

def scrape_jobbank(keywords=None, location=None):
    keywords = keywords or KEYWORDS
    location = location or LOCATION
    all_jobs = []
    
    for keyword in keywords:
        print(f\"  🔍 Job Bank: '{keyword}'...\")
        url = f\"https://www.jobbank.gc.ca/jobsearch/jobsearch?searchstring={keyword.replace(' ', '+')}&locationstring={location.replace(' ', '+')}\"
        
        try:
            response = requests.get(url, headers={'User-Agent': 'Mozilla/5.0'}, timeout=10)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            for card in soup.find_all('article', class_='resultJobItem', limit=10):
                try:
                    title = card.find('a', class_='resultJobItem-title')
                    company = card.find('span', class_='resultJobItem-employer')
                    
                    if title and company:
                        all_jobs.append({
                            'company': company.text.strip(),
                            'title': title.text.strip(),
                            'location': location,
                            'source': 'Job Bank',
                            'url': 'https://www.jobbank.gc.ca' + title['href'],
                            'job_type': 'Full-time',
                            'salary': '',
                            'description': ''
                        })
                except:
                    continue
            
            time.sleep(2)
        except Exception as e:
            print(f\"    ❌ {e}\")
    
    print(f\"  ✅ Job Bank: {len(all_jobs)} jobs\")
    return all_jobs
"@ | Out-File -FilePath "scrapers\jobbank_scraper.py" -Encoding UTF8

# enhanced_main.py
@"
#!/usr/bin/env python3
\"\"\"Enhanced Job Search Automation v2.0\"\"\"
import sys
import os
from datetime import datetime, timedelta
from utils.database import db
from config_manager import ConfigManager
from smart_filter import SmartFilter
from gmail_notifier import gmail
from notifications.whatsapp_notifier import notifier
from scrapers.indeed_scraper import scrape_indeed
from scrapers.jobbank_scraper import scrape_jobbank

CONFIG_SHEET_ID = os.getenv('CONFIG_SHEET_ID', 'YOUR_CONFIG_SHEET_ID')

def main():
    print(\"=\" * 70)
    print(\"🤖 ENHANCED JOB SEARCH AUTOMATION v2.0\")
    print(f\"📅 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\")
    print(\"=\" * 70)
    
    # Load config
    print(\"\\n⚙️  Loading configuration...\")
    config = ConfigManager(CONFIG_SHEET_ID)
    
    keywords = config.get('keywords')
    location = config.get('location')
    whatsapp = config.get('whatsapp')
    email = config.get('email')
    priority_keywords = config.get('priority_keywords', [])
    job_sources = config.get('job_sources', [])
    
    print(f\"   Keywords: {', '.join(keywords)}\")
    print(f\"   Location: {location}\")
    print(f\"   Sources: {', '.join(job_sources)}\")
    
    # Smart filter
    smart_filter = SmartFilter(priority_keywords)
    
    # Scrape
    print(\"\\n🔍 Scraping job boards...\")
    all_jobs = []
    
    if 'Indeed' in job_sources:
        try:
            all_jobs.extend(scrape_indeed(keywords, location))
        except Exception as e:
            print(f\"❌ Indeed: {e}\")
    
    if 'Job Bank' in job_sources or 'JobBank' in job_sources:
        try:
            all_jobs.extend(scrape_jobbank(keywords, location))
        except Exception as e:
            print(f\"❌ Job Bank: {e}\")
    
    print(f\"\\n📊 Raw jobs: {len(all_jobs)}\")
    
    # Filter
    existing_jobs = db.get_all_jobs(limit=2000)
    print(\"\\n🧠 Smart filtering...\")
    filtered_jobs = smart_filter.filter_and_rank(all_jobs, existing_jobs)
    
    print(f\"   Unique: {len(filtered_jobs)}\")
    if filtered_jobs:
        print(f\"   Top score: {filtered_jobs[0]['relevance_score']}\")
    
    # Save
    print(\"\\n💾 Saving...\")
    new_count = 0
    for job in filtered_jobs:
        if db.add_job(job):
            new_count += 1
    
    print(f\"✅ Added {new_count} new jobs\")
    
    # Stats
    stats = db.get_stats()
    print(f\"\\n📈 Stats:\")
    print(f\"   Total: {stats.get('total', 0)}\")
    print(f\"   New: {stats.get('New', 0)}\")
    print(f\"   Applied: {stats.get('Applied', 0)}\")
    print(f\"   Interview: {stats.get('Interview', 0)}\")
    
    # Notifications
    if new_count > 0:
        top_jobs = filtered_jobs[:5]
        
        # WhatsApp
        print(\"\\n📱 Sending WhatsApp...\")
        whatsapp_msg = f\"\"\"🚀 *Job Alert* - {datetime.now().strftime('%Y-%m-%d')}

📊 *{new_count} new jobs found!*

🏆 *Top 5:*

\"\"\"
        for i, job in enumerate(top_jobs, 1):
            whatsapp_msg += f\"{i}. *{job['title']}*\\n   {job['company']} • Score: {job['relevance_score']}\\n   {job['url']}\\n\\n\"
        
        whatsapp_msg += f\"\"\"📈 *Stats:*
• New: {stats.get('New', 0)}
• Applied: {stats.get('Applied', 0)}
• Interviews: {stats.get('Interview', 0)}

🎯 Apply to 5 jobs today!\"\"\"
        
        notifier.send_message(whatsapp_msg)
        
        # Gmail
        print(\"\\n📧 Sending Gmail...\")
        gmail.send_daily_alert(email, filtered_jobs, stats)
    
    # Follow-ups
    print(\"\\n⏰ Checking follow-ups...\")
    followup_days = config.get('followup_days', 7)
    cutoff_date = (datetime.now() - timedelta(days=followup_days)).strftime('%Y-%m-%d')
    
    cursor = db.conn.cursor()
    cursor.execute('''
        SELECT * FROM jobs 
        WHERE status = 'Applied' 
        AND date_applied <= ? 
        AND date_applied IS NOT NULL
    ''', (cutoff_date,))
    
    followup_jobs = cursor.fetchall()
    
    if followup_jobs:
        print(f\"   {len(followup_jobs)} need follow-up\")
        columns = [desc[0] for desc in cursor.description]
        followup_list = [dict(zip(columns, row)) for row in followup_jobs]
        
        gmail.send_followup_reminder(email, followup_list)
        notifier.send_message(
            f\"⏰ *Follow-Up*\\n\\n{len(followup_jobs)} applications from {followup_days}+ days ago. Follow up today! 💼\"
        )
    
    print(\"\\n✨ Complete!\")
    print(\"=\" * 70)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print(\"\\n⚠️  Stopped\")
        sys.exit(0)
    except Exception as e:
        print(f\"\\n❌ Error: {e}\")
        import traceback
        traceback.print_exc()
        sys.exit(1)
"@ | Out-File -FilePath "enhanced_main.py" -Encoding UTF8

# dashboard/app.py
@"
\"\"\"Flask Dashboard\"\"\"
from flask import Flask, render_template, request, redirect, url_for
from utils.database import db
from utils.config import FLASK_SECRET_KEY, DASHBOARD_PORT

app = Flask(__name__)
app.secret_key = FLASK_SECRET_KEY

@app.route('/')
def index():
    status = request.args.get('status', 'all')
    jobs = db.get_all_jobs(status=status.capitalize() if status != 'all' else None, limit=200)
    stats = db.get_stats()
    return render_template('index.html', jobs=jobs, stats=stats, filter=status)

@app.route('/update/<job_id>', methods=['POST'])
def update(job_id):
    status = request.form.get('status')
    notes = request.form.get('notes', '')
    db.update_status(job_id, status, notes)
    return redirect(url_for('index'))

if __name__ == '__main__':
    print(f\"🚀 Dashboard: http://localhost:{DASHBOARD_PORT}\")
    app.run(host='0.0.0.0', port=DASHBOARD_PORT, debug=True)
"@ | Out-File -FilePath "dashboard\app.py" -Encoding UTF8

# dashboard/templates/index.html
@"
<!DOCTYPE html>
<html>
<head>
    <title>Job Tracker Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: system-ui; background: #f5f5f5; padding: 20px; }
        .container { max-width: 1400px; margin: 0 auto; }
        header { background: white; padding: 30px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #2196F3; margin-bottom: 8px; }
        .subtitle { color: #666; font-size: 14px; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .stat-card { background: white; padding: 20px; border-radius: 8px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .stat-card h3 { font-size: 36px; color: #2196F3; margin-bottom: 8px; }
        .stat-card p { color: #666; font-size: 14px; }
        .filters { background: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .btn { display: inline-block; padding: 10px 20px; background: #2196F3; color: white; text-decoration: none; border-radius: 4px; margin-right: 10px; border: none; cursor: pointer; }
        .btn:hover { background: #1976D2; }
        table { width: 100%; background: white; border-radius: 8px; padding: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); border-collapse: collapse; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #eee; }
        th { background: #f5f5f5; font-weight: 600; color: #666; font-size: 13px; text-transform: uppercase; }
        tr:hover { background: #f9f9f9; }
        .status-new { color: #2196F3; font-weight: 600; }
        .status-applied { color: #FF9800; font-weight: 600; }
        .status-interview { color: #4CAF50; font-weight: 600; }
        .status-rejected { color: #F44336; font-weight: 600; }
        select { padding: 6px; border: 1px solid #ddd; border-radius: 4px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🎯 Job Tracker Dashboard</h1>
            <p class="subtitle">Vancouver BC • IT Support, Deskside, Cybersecurity Analyst</p>
        </header>

        <div class="stats">
            <div class="stat-card">
                <h3>{{ stats.get('total', 0) }}</h3>
                <p>Total Jobs</p>
            </div>
            <div class="stat-card">
                <h3>{{ stats.get('New', 0) }}</h3>
                <p>New</p>
            </div>
            <div class="stat-card">
                <h3>{{ stats.get('Applied', 0) }}</h3>
                <p>Applied</p>
            </div>
            <div class="stat-card">
                <h3>{{ stats.get('Interview', 0) }}</h3>
                <p>Interviews</p>
            </div>
        </div>

        <div class="filters">
            <a href="/?status=all" class="btn">All</a>
            <a href="/?status=new" class="btn">New</a>
            <a href="/?status=applied" class="btn">Applied</a>
            <a href="/?status=interview" class="btn">Interviews</a>
        </div>

        <table>
            <thead>
                <tr>
                    <th>Date</th>
                    <th>Company</th>
                    <th>Title</th>
                    <th>Source</th>
                    <th>Score</th>
                    <th>Status</th>
                    <th>Actions</th>
                </tr>
            </thead>
            <tbody>
                {% for job in jobs %}
                <tr>
                    <td>{{ job.date_found }}</td>
                    <td><strong>{{ job.company }}</strong></td>
                    <td>{{ job.title }}</td>
                    <td>{{ job.source }}</td>
                    <td>{{ job.relevance_score }}</td>
                    <td class="status-{{ job.status.lower() }}">{{ job.status }}</td>
                    <td>
                        <a href="{{ job.url }}" target="_blank" class="btn" style="padding: 6px 12px; font-size: 12px;">View</a>
                        <form method="POST" action="/update/{{ job.job_id }}" style="display:inline">
                            <select name="status" onchange="this.form.submit()">
                                <option>Update...</option>
                                <option value="Applied">Applied</option>
                                <option value="Interview">Interview</option>
                                <option value="Rejected">Rejected</option>
                                <option value="Offer">Offer</option>
                            </select>
                        </form>
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>
</body>
</html>
"@ | Out-File -FilePath "dashboard\templates\index.html" -Encoding UTF8

# .env.example
@"
# Google Sheets Config
SPREADSHEET_ID = 'your_spreadsheet_id'
CONFIG_SHEET_ID = 'your_config_sheet_id'

# Twilio WhatsApp Credentials
TWILIO_ACCOUNT_SID = 'your_account_sid'
TWILIO_AUTH_TOKEN = 'your_auth_token'
TWILIO_WHATSAPP_NUMBER = 'whatsapp:+14155238886'

# Flask Settings
FLASK_APP = 'app.py'
FLASK_ENV = 'development'
"@ | Out-File -FilePath ".env.example" -Encoding UTF8

# requirements.txt
@"
requests==2.31.0
beautifulsoup4==4.12.2
selenium==4.15.2
gspread==5.12.0
oauth2client==4.1.3
flask==3.0.0
twilio==8.10.0
python-dotenv==1.0.0
schedule==1.2.0
webdriver-manager==4.0.1
lxml==4.9.3
pandas==2.1.3
google-api-python-client==2.108.0
google-auth-httplib2==0.1.1
google-auth-oauthlib==1.1.0
"@ | Out-File -FilePath "requirements.txt" -Encoding UTF8

Write-Host "All files created. Review and edit .env and add credentials.json + client_secret.json to repo root." -ForegroundColor Green
