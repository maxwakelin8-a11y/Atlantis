// Atlantis: "Start from an assessment" read SEQTA through BetterSEQTA+. In Atlantis it will read
// the SEQTA cache once the sync engine exists (PRD §7d); until then it says so.

const NOT_YET = "SEQTA assessments come to Docs with the SEQTA sync (a later step). Pick a template for now.";

export async function upcomingAssessments(): Promise<unknown[]> {
  throw new Error(NOT_YET);
}

export async function assessmentDetails(_id: number, _metaclass: number): Promise<unknown> {
  throw new Error(NOT_YET);
}
