"""Extract unique newspaper names from parquet files and parse state."""
import pyarrow.parquet as pq
import os, re, csv, sys

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

parquet_dir = 'C:/Users/ammonsj/Ideas/data_parquet'
outfile = 'C:/Users/ammonsj/Ideas/data_panels/newspaper_states.csv'

# Ordered by length (longest first) to avoid partial matches
# e.g., "W. Va." must match before "Va."
state_lookup = [
    ("W. Va.", "WV"), ("N.M.", "NM"), ("N.C.", "NC"), ("N.D.", "ND"),
    ("N.H.", "NH"), ("N.J.", "NJ"), ("N.Y.", "NY"), ("S.C.", "SC"),
    ("S.D.", "SD"), ("D.C.", "DC"), ("R.I.", "RI"),
    ("Ala.", "AL"), ("Ariz.", "AZ"), ("Ark.", "AR"), ("Calif.", "CA"),
    ("Colo.", "CO"), ("Conn.", "CT"), ("Del.", "DE"),
    ("Fla.", "FL"), ("Ga.", "GA"), ("Ill.", "IL"),
    ("Ind.", "IN"), ("Kan.", "KS"), ("Ky.", "KY"),
    ("La.", "LA"), ("Me.", "ME"), ("Md.", "MD"), ("Mass.", "MA"),
    ("Mich.", "MI"), ("Minn.", "MN"), ("Miss.", "MS"), ("Mo.", "MO"),
    ("Mont.", "MT"), ("Neb.", "NE"), ("Nev.", "NV"),
    ("Okla.", "OK"), ("Or.", "OR"), ("Pa.", "PA"),
    ("Tenn.", "TN"), ("Tex.", "TX"),
    ("Vt.", "VT"), ("Va.", "VA"), ("Wash.", "WA"),
    ("Wis.", "WI"), ("Wyo.", "WY"),
    # Full-word states (no period)
    ("Idaho", "ID"), ("Iowa", "IA"), ("Ohio", "OH"), ("Utah", "UT"),
    # Short forms sometimes used
    ("O.", "OH"),
]

loc_pattern = re.compile(r'\(([^)]+)\)')
bracket_pattern = re.compile(r'\[([^\]]+)\]')

def parse_state(name):
    """Parse state from newspaper name. Checks parenthesized location first, then brackets."""
    m = loc_pattern.search(name)
    loc = m.group(1) if m else ""

    # Also grab all bracket contents for fallback
    brackets = bracket_pattern.findall(name)
    # Filter out [volume] and [microfilm reel] etc
    bracket_locs = [b for b in brackets if not any(x in b.lower() for x in ['volume', 'microfilm', 'reel'])]

    # Search in parenthesized location
    if loc:
        for abbr, code in state_lookup:
            if abbr in loc:
                return code

    # Search in bracket locations like [Va.] or [Ind.]
    for bl in bracket_locs:
        for abbr, code in state_lookup:
            if abbr in bl:
                return code

    return ""

def parse_city(name):
    m = loc_pattern.search(name)
    if not m:
        return ""
    loc = m.group(1)
    return loc.split(",")[0].strip()

# Gather all unique newspaper names
all_names = set()
for yr in range(1774, 1961):
    fp = os.path.join(parquet_dir, f'articles_{yr}.parquet')
    if os.path.exists(fp):
        table = pq.read_table(fp, columns=['newspaper_name'])
        names = table.column('newspaper_name').to_pylist()
        all_names.update(names)

print(f"Total unique newspaper names: {len(all_names)}")

# Parse and write CSV
os.makedirs(os.path.dirname(outfile), exist_ok=True)
with open(outfile, 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(['newspaper_name', 'city', 'state'])
    parsed = 0
    for name in sorted(all_names):
        state = parse_state(name)
        city = parse_city(name)
        writer.writerow([name, city, state])
        if state:
            parsed += 1

print(f"Parsed state for {parsed} / {len(all_names)} newspapers")
print(f"Saved to {outfile}")
