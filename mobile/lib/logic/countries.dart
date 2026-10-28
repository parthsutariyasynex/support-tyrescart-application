/// Calling codes for "New chat" and the contact's country (ISO code, dial code, name). Reference data, not business data.
class PhoneCountry {
  const PhoneCountry(this.code, this.dial, this.name);
  final String code;
  final String dial;
  final String name;
  String get flag => String.fromCharCodes(code.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 65));
}

const phoneCountries = <PhoneCountry>[
  PhoneCountry('AE', '971', 'United Arab Emirates'),
  PhoneCountry('IN', '91', 'India'),
  PhoneCountry('SA', '966', 'Saudi Arabia'),
  PhoneCountry('OM', '968', 'Oman'),
  PhoneCountry('QA', '974', 'Qatar'),
  PhoneCountry('KW', '965', 'Kuwait'),
  PhoneCountry('BH', '973', 'Bahrain'),
  PhoneCountry('PK', '92', 'Pakistan'),
  PhoneCountry('BD', '880', 'Bangladesh'),
  PhoneCountry('LK', '94', 'Sri Lanka'),
  PhoneCountry('NP', '977', 'Nepal'),
  PhoneCountry('PH', '63', 'Philippines'),
  PhoneCountry('EG', '20', 'Egypt'),
  PhoneCountry('JO', '962', 'Jordan'),
  PhoneCountry('LB', '961', 'Lebanon'),
  PhoneCountry('SY', '963', 'Syria'),
  PhoneCountry('IQ', '964', 'Iraq'),
  PhoneCountry('IR', '98', 'Iran'),
  PhoneCountry('YE', '967', 'Yemen'),
  PhoneCountry('SD', '249', 'Sudan'),
  PhoneCountry('MA', '212', 'Morocco'),
  PhoneCountry('DZ', '213', 'Algeria'),
  PhoneCountry('TN', '216', 'Tunisia'),
  PhoneCountry('TR', '90', 'Türkiye'),
  PhoneCountry('AF', '93', 'Afghanistan'),
  PhoneCountry('GB', '44', 'United Kingdom'),
  PhoneCountry('US', '1', 'United States / Canada'),
  PhoneCountry('AU', '61', 'Australia'),
  PhoneCountry('NZ', '64', 'New Zealand'),
  PhoneCountry('IE', '353', 'Ireland'),
  PhoneCountry('DE', '49', 'Germany'),
  PhoneCountry('FR', '33', 'France'),
  PhoneCountry('IT', '39', 'Italy'),
  PhoneCountry('ES', '34', 'Spain'),
  PhoneCountry('PT', '351', 'Portugal'),
  PhoneCountry('NL', '31', 'Netherlands'),
  PhoneCountry('BE', '32', 'Belgium'),
  PhoneCountry('CH', '41', 'Switzerland'),
  PhoneCountry('AT', '43', 'Austria'),
  PhoneCountry('SE', '46', 'Sweden'),
  PhoneCountry('NO', '47', 'Norway'),
  PhoneCountry('DK', '45', 'Denmark'),
  PhoneCountry('FI', '358', 'Finland'),
  PhoneCountry('PL', '48', 'Poland'),
  PhoneCountry('RO', '40', 'Romania'),
  PhoneCountry('GR', '30', 'Greece'),
  PhoneCountry('RU', '7', 'Russia / Kazakhstan'),
  PhoneCountry('UA', '380', 'Ukraine'),
  PhoneCountry('CN', '86', 'China'),
  PhoneCountry('HK', '852', 'Hong Kong'),
  PhoneCountry('JP', '81', 'Japan'),
  PhoneCountry('KR', '82', 'South Korea'),
  PhoneCountry('SG', '65', 'Singapore'),
  PhoneCountry('MY', '60', 'Malaysia'),
  PhoneCountry('ID', '62', 'Indonesia'),
  PhoneCountry('TH', '66', 'Thailand'),
  PhoneCountry('VN', '84', 'Vietnam'),
  PhoneCountry('ZA', '27', 'South Africa'),
  PhoneCountry('NG', '234', 'Nigeria'),
  PhoneCountry('KE', '254', 'Kenya'),
  PhoneCountry('ET', '251', 'Ethiopia'),
  PhoneCountry('UG', '256', 'Uganda'),
  PhoneCountry('TZ', '255', 'Tanzania'),
  PhoneCountry('GH', '233', 'Ghana'),
  PhoneCountry('BR', '55', 'Brazil'),
  PhoneCountry('MX', '52', 'Mexico'),
  PhoneCountry('AR', '54', 'Argentina'),
];

/// The country of a number with its calling code (longest code first), or null
PhoneCountry? countryOfNumber(String waId) {
  final sorted = [...phoneCountries]..sort((a, b) => b.dial.length.compareTo(a.dial.length));
  for (final c in sorted) {
    if (waId.startsWith(c.dial)) return c;
  }
  return null;
}

PhoneCountry? countryByCode(String? code) => code == null ? null : phoneCountries.where((c) => c.code == code.toUpperCase()).firstOrNull;
