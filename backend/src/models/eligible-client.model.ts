export interface EligibleClient {
  id: string;
  experimentId: string;
  clientCode: string;
  uploadBatchId: string;
  createdAt: Date;
}

export interface ClientListUpload {
  id: string;
  experimentId: string;
  fileName: string;
  fileSizeBytes: number;
  s3Key: string;
  totalRows: number;
  validRows: number;
  duplicateRows: number;
  invalidRows: number;
  status: UploadStatus;
  errorMessage: string | null;
  uploadedBy: string | null;
  createdAt: Date;
  completedAt: Date | null;
}

export type UploadStatus = 'pending' | 'processing' | 'completed' | 'failed';

export interface UploadResult {
  uploadId: string;
  totalRows: number;
  validRows: number;
  duplicateRows: number;
  invalidRows: number;
  s3Key: string;
}

export interface UploadMode {
  mode: 'replace' | 'append';
}
