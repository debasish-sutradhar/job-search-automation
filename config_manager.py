"""Dynamic Configuration Manager - Reads settings from Google Sheet"""
import gspread
from oauth2client.service_account import ServiceAccountCredentials

class ConfigManager:
    def __init__(self, config_sheet_id):
        self.sheet_id = config_sheet_id
        self.config = self._load_config()
    
    def _load_config(self):
        try:
            scope = ["https://spreadsheets.google.com/feeds",
                     "https://www.googleapis.com/auth/drive"]
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
            
            print(f"✅ Config loaded: {len(config)} settings")
            return config
            
        except Exception as e:
            print(f"⚠️  Config load failed: {e}, using defaults")
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