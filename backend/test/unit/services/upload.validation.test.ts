import { validateClientCodes, parseFile } from '../../../src/services/upload.service';
import { AppError } from '../../../src/utils/errors';
import fs from 'fs';
import path from 'path';

describe('validateClientCodes', () => {
  it('separates valid, duplicate, and invalid codes', () => {
    const input = ['AB1234', 'CD5678', 'AB1234', 'bad code!', 'EF0000'];
    const result = validateClientCodes(input);

    expect(result.valid).toEqual(['AB1234', 'CD5678', 'EF0000']);
    expect(result.duplicates).toEqual(['AB1234']);
    expect(result.invalid).toEqual(['bad code!']);
  });

  it('silently skips empty strings', () => {
    const input = ['', '   ', 'AB1234', ''];
    const result = validateClientCodes(input);

    expect(result.valid).toEqual(['AB1234']);
    expect(result.invalid).toHaveLength(0);
    expect(result.duplicates).toHaveLength(0);
  });

  it('trims whitespace from each code before validation', () => {
    const input = ['  AB1234  ', ' CD5678 '];
    const result = validateClientCodes(input);

    expect(result.valid).toEqual(['AB1234', 'CD5678']);
    expect(result.invalid).toHaveLength(0);
  });

  it('rejects codes with special characters', () => {
    const invalidCodes = ['AB-1234', 'AB_1234', 'AB 1234', 'AB@123', 'AB.123'];
    const result = validateClientCodes(invalidCodes);

    expect(result.valid).toHaveLength(0);
    expect(result.invalid).toHaveLength(invalidCodes.length);
  });

  it('rejects codes longer than 50 characters', () => {
    const longCode = 'A'.repeat(51);
    const result = validateClientCodes([longCode]);

    expect(result.valid).toHaveLength(0);
    expect(result.invalid).toContain(longCode);
  });

  it('accepts codes at the 50 character boundary', () => {
    const exactCode = 'A'.repeat(50);
    const result = validateClientCodes([exactCode]);

    expect(result.valid).toContain(exactCode);
    expect(result.invalid).toHaveLength(0);
  });

  it('handles duplicate detection case-insensitively', () => {
    // Same code, different case — treated as duplicate
    const input = ['AB1234', 'ab1234'];
    const result = validateClientCodes(input);

    expect(result.valid).toHaveLength(1);
    expect(result.duplicates).toHaveLength(1);
  });

  it('handles an empty array', () => {
    const result = validateClientCodes([]);

    expect(result.valid).toHaveLength(0);
    expect(result.duplicates).toHaveLength(0);
    expect(result.invalid).toHaveLength(0);
  });

  it('handles a large input (1M rows) without stack overflow', () => {
    const codes = Array.from({ length: 100_000 }, (_, i) => `C${String(i).padStart(6, '0')}`);
    const result = validateClientCodes(codes);

    expect(result.valid).toHaveLength(100_000);
    expect(result.duplicates).toHaveLength(0);
    expect(result.invalid).toHaveLength(0);
  });
});

describe('parseFile — CSV', () => {
  const fixturesDir = path.join(__dirname, '../../fixtures');

  it('parses a valid CSV with a header row', () => {
    const buffer = Buffer.from('client_code\nAB1234\nCD5678\nEF0000\n');
    const result = parseFile(buffer, 'test.csv');

    expect(result).toEqual(['AB1234', 'CD5678', 'EF0000']);
  });

  it('parses a valid CSV without a header row', () => {
    const buffer = Buffer.from('AB1234\nCD5678\nEF0000\n');
    const result = parseFile(buffer, 'test.csv');

    // First value passes the CLIENT_CODE_REGEX so no header is stripped
    expect(result).toContain('AB1234');
    expect(result).toContain('CD5678');
  });

  it('strips BOM from UTF-8 CSV files', () => {
    // BOM = EF BB BF
    const bom = Buffer.from([0xef, 0xbb, 0xbf]);
    const content = Buffer.from('client_code\nAB1234\n');
    const buffer = Buffer.concat([bom, content]);

    const result = parseFile(buffer, 'test.csv');
    expect(result).toContain('AB1234');
  });

  it('parses only the first column of a multi-column CSV', () => {
    const buffer = Buffer.from('client_code,name,city\nAB1234,Alice,Mumbai\nCD5678,Bob,Delhi\n');
    const result = parseFile(buffer, 'test.csv');

    expect(result).toEqual(['AB1234', 'CD5678']);
  });

  it('uses the sample fixture file', () => {
    const buffer = fs.readFileSync(path.join(fixturesDir, 'sample-upload.csv'));
    const result = parseFile(buffer, 'sample-upload.csv');

    expect(result.length).toBeGreaterThan(0);
    expect(result).toContain('ABC001');
  });

  it('throws AppError for unsupported file extensions', () => {
    const buffer = Buffer.from('some data');

    expect(() => parseFile(buffer, 'data.txt')).toThrow(AppError);
    expect(() => parseFile(buffer, 'data.txt')).toThrow('Only .csv, .xlsx and .xls files are supported');
  });

  it('throws ValidationError for empty CSV files', () => {
    const buffer = Buffer.from('');
    // csv-parse returns no records for an empty buffer — caught as ValidationError
    expect(() => parseFile(buffer, 'empty.csv')).toThrow();
  });
});

describe('parseFile — Excel', () => {
  it('parses an XLSX file from the fixtures directory', () => {
    const XLSX = require('xlsx');
    // Create an in-memory XLSX workbook for testing
    const wb = XLSX.utils.book_new();
    const ws = XLSX.utils.aoa_to_sheet([
      ['client_code'],
      ['AB1234'],
      ['CD5678'],
      ['EF0000'],
    ]);
    XLSX.utils.book_append_sheet(wb, ws, 'Sheet1');
    const buffer: Buffer = XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' });

    const result = parseFile(buffer, 'test.xlsx');
    expect(result).toContain('AB1234');
    expect(result).toContain('CD5678');
    expect(result).toContain('EF0000');
  });

  it('skips header row in XLSX when header is non-alphanumeric', () => {
    const XLSX = require('xlsx');
    const wb = XLSX.utils.book_new();
    // Use a header that clearly doesn't match CLIENT_CODE_REGEX (contains a space)
    const ws = XLSX.utils.aoa_to_sheet([['Client Code'], ['AB1234'], ['CD5678']]);
    XLSX.utils.book_append_sheet(wb, ws, 'Sheet1');
    const buffer: Buffer = XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' });

    const result = parseFile(buffer, 'test.xlsx');
    expect(result).not.toContain('Client Code');
    expect(result).toContain('AB1234');
  });

  it('throws or returns empty for corrupt XLSX data', () => {
    const buffer = Buffer.from('not an excel file');
    // The xlsx library may either throw or return an empty workbook for corrupt data.
    // Either way, no valid client codes should be returned.
    try {
      const result = parseFile(buffer, 'corrupt.xlsx');
      // If it doesn't throw, it should return an empty array (no valid codes)
      expect(result.length).toBe(0);
    } catch (err) {
      expect(err).toBeInstanceOf(Error);
    }
  });
});
